### Task 12: ExpandGrid widget and view models

**Files:**
- Create: `UI/Widgets/ExpandGrid.lua`, `UI/Tabs/CharactersView.lua`, `UI/Tabs/PlannerView.lua`
- Modify: `FabricationStation.toc` (all three between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`, before the phase-3 tab files), `.luacheckrc` (`CreateScrollBoxListLinearView`, `CreateDataProvider`, `ScrollUtil`, `RAID_CLASS_COLORS` in `read_globals`)
- Test: `tests/ui/expand_grid_spec.lua`, `tests/ui/views_spec.lua`

**Interfaces:**
- Consumes: `AltRow`, `ScheduleRow`, `Pool`, checklist rows, `ns.UI.FormatMoney` (1a `UI/Util.lua`; files extend the existing `ns.UI` table, `ns.UI = ns.UI or {}`).
- Produces: `ns.UI.ExpandGrid.Layout(rows, expanded, rowHeight) -> { { key, kind = "row"|"detail", height } }` where `rows = { { key, detailHeight } }`; `ns.UI.ExpandGrid.New(parent, columns) -> grid` with `grid:SetRows(rows)`, `grid:Toggle(key)`, `grid:SetRowRenderer(fn(frame, row))`, `grid:SetDetailRenderer(fn(frame, row))`; `ns.UI.CharactersView.FormatDuration(seconds|nil) -> string`; `ns.UI.CharactersView.KnowledgeCell(summary) -> string`; `ns.UI.CharactersView.Row(altRow, now) -> { name, gold, age, staleAge, profs = { { label, skill, conc, concUrgent, kp, spec, moxie, cds } }, empty|nil }`; `ns.UI.PlannerView.ConcentrationLines(pools, now, max) -> { {left, right, urgent} }`; `ns.UI.PlannerView.KnowledgeLines(checklistRows, max) -> { {left, right} }`.

- [ ] **Step 1: Write the failing tests**

```lua
it("Layout inserts detail rows", function()
  local l = ns.UI.ExpandGrid.Layout({{key="a"}, {key="b", detailHeight=60}, {key="c"}}, {b = true}, 20)
  assert.same({{key="a", kind="row", height=20}, {key="b", kind="row", height=20},
               {key="b", kind="detail", height=60}, {key="c", kind="row", height=20}}, l)
end)
it("FormatDuration", function()
  local F = ns.UI.CharactersView.FormatDuration
  assert.same({"now", "<1m", "45m", "1h 0m", "2d 12h", "—"}, {F(0), F(30), F(2700), F(3600), F(216000), F(nil)})
end)
it("Row for Aria", function()
  local r = ns.UI.CharactersView.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW); local p = r.profs[1]
  assert.same({"Aria", "1h 0m", false}, {r.name, r.age, r.staleAge})
  assert.same({"Blacksmithing", "85/100", "2", "17/63 (+4)", "120", "1 · 2h 0m"}, {p.label, p.skill, p.kp, p.spec, p.moxie, p.cds})
  assert.same({"400/1000 · 2d 12h", false}, {p.conc, p.concUrgent})
end)
it("Row for Bren and Cato", function()
  local b = ns.UI.CharactersView.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
  assert.same({"10d 0h", true, "1000/1000 · Full", true, "3", "—", "—"},
    {b.age, b.staleAge, b.profs[1].conc, b.profs[1].concUrgent, b.profs[1].kp, b.profs[1].spec, b.profs[1].moxie})
  local c = ns.UI.CharactersView.Row(A:GetAltRow("Cato-Silvermoon", NOW), NOW)
  assert.equal("Open your professions on this character", c.empty)
end)
it("KnowledgeCell", function()
  local K = ns.UI.CharactersView.KnowledgeCell
  assert.same({"?", "?", "2"}, {K({status = "noData"}), K({status = "unknown"}), K({status = "ok", weeklyLeft = 2})})
end)
it("ConcentrationLines sorted by fullAt", function()
  local l = ns.UI.PlannerView.ConcentrationLines(A:GetPools(NOW), NOW, 6)
  assert.same({"Bren-Silvermoon Herbalism", "Full", true}, {l[1][1], l[1][2], l[1].urgent})
  assert.equal("Aria-Silvermoon Blacksmithing", l[2][1])
end)
it("KnowledgeLines total first", function()
  local l = ns.UI.PlannerView.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 6)
  assert.same({{"Total", "5 KP"}, {"Bren-Silvermoon Herbalism", "3 KP"}, {"Aria-Silvermoon Blacksmithing", "2 KP"}}, l)
end)
```

- [ ] **Step 2: Run** — `busted tests/ui` → FAIL.

- [ ] **Step 3: Implement.** FormatDuration: `nil → "—"`, `<= 0 → "now"`, `< 60 → "<1m"`, `< 3600 → "Nm"`, `< 86400 → "Nh Mm"`, else `"Nd Hh"`. Row cells: `skill = skill .. "/" .. maxSkill`; `conc = now .. "/" .. max .. " · " .. (secondsToFull == 0 and "Full" or FormatDuration(secondsToFull))`, `"—"` when nil; `concUrgent = secondsToFull ~= nil and secondsToFull <= capWarnHours * 3600`; `spec = spent .. "/" .. max .. " (+" .. unspent .. ")"` or `"—"`; `kp` via `KnowledgeCell(summary)` (`weeklyLeft` as string, `"?"` for noData/unknown); `cds = #cooldowns .. " · " .. (all ready and "ready" or FormatDuration(soonest pending readyAt - now))`, `"—"` when no cooldowns; `gold = ns.UI.FormatMoney(gold)`. `ExpandGrid.New`: `CreateScrollBoxListLinearView()` with `SetElementExtentCalculator` returning each layout entry's `height`, `CreateDataProvider(Layout(...))`, `ScrollUtil.InitScrollBoxListWithScrollBar`; header row of column labels (`columns = { {key, label, width} }`); clicking a row calls `Toggle(key)` and rebuilds the data provider.

- [ ] **Step 4: Run** — `busted tests/ui` → PASS; `luacheck .` clean.

- [ ] **Step 5: Commit**

```bash
git add UI/Widgets/ExpandGrid.lua UI/Tabs/CharactersView.lua UI/Tabs/PlannerView.lua tests/ui FabricationStation.toc .luacheckrc
git commit -m "feat: add expandable grid widget and Characters/Planner view models"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 12 (ExpandGrid on a plain ScrollFrame with pooled rows — the test stubs have no ScrollBox constructors; a pure `Layout(width)` that hides lower-priority columns; the Characters grid's full width (~1320 px) far exceeds the 516 px minimum).
- Layout lessons (global constraints): minimum content width 516 px; the flexible column keeps ≥ 120 px there; hide columns by priority below that (recomputed on size change); anchor from both edges when the flexible column isn't first; truncated content goes into tooltips; specs at 516 px (shared fake font strings record SetPoint/SetWidth); "+N" affordance for overflowing chips/lists.
- View models must render every status the modules return: Alts off ("Alts is turned off"), hidden, noProfession ("<char> does not have this profession"), noData ("No recipe list yet: open this profession on any character"), notScanned ("Open this profession on <char>"), noSpec, noRecipes; knowledge status ~= "ok" → "?" (never "0 left"); concentration nil → "—", capped → "Full"; stale rows show their age.
- Carry from Task 7: Characters header knowledge sum and any knowledge total show a "data build X (outdated)" marker/tooltip when ns.GameData.Status is outdated/mismatched (never blank the data).
- Carry from Task 11 (PlannerView spec-advice model): nil gain/gainPerPoint → "?" (never FormatMoney(nil)); affordable nil → no tag; when every row's gain is nil show "Spec effect data not in this GameData build (<build>)" instead of a ranking; one message per status. (Task 14 will compute advice lazily; the view model must not call GetSpecAdvice itself.)
- Pure view models: no frame code, no WoW globals beyond what the plan names; money via ns.UI.FormatMoney / CompactMoney; ages via ns.UI.FormatAge.
