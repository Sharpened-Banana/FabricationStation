### Task 15: Dashboard widgets

**Files:**
- Create: `UI/AltsDashboard.lua`
- Modify: `FabricationStation.toc` (after `UI\Tooltips.lua`/`UI\AltsTooltips.lua`)
- Test: `tests/ui/dashboard_widgets_spec.lua`

**Interfaces:**
- Consumes: `Dashboard:RegisterWidget(id, def)` (1b; `def = { order, title, build(frame), refresh(frame) }`, same id replaces; 1b isolates a failing widget), `Planner:GetKnowledgeChecklist`, `ns.UI.PlannerView.KnowledgeLines`, `MainWindow:SelectTab`.
- Produces: widget `"altsKnowledge"` `{ order = 65, title = "Knowledge left this week" }`. No concentration widget: 1b already ships `"concentration"` (order 30, every alt sorted by full-at), so a phase-3 `"altsConcentration"` would duplicate it. Existing widget orders: 1b 10/20/30, phase 2 40/50.

- [ ] **Step 1: Write the failing test**

```lua
local w = env.registered.widgets
assert.same({65, "Knowledge left this week"}, {w.altsKnowledge.order, w.altsKnowledge.title})
assert.is_function(w.altsKnowledge.build); assert.is_function(w.altsKnowledge.refresh)
assert.is_nil(w.altsConcentration)
```

- [ ] **Step 2: Run** — `busted tests/ui/dashboard_widgets_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** In `Alts:OnEnable` (or Planner's), `Dashboard:RegisterWidget("altsKnowledge", def)`. `build(frame)` creates 6 two-column font-string lines; `refresh(frame)` fills them from `KnowledgeLines(Planner:GetKnowledgeChecklist(now), 6)`; clicking the widget calls `MainWindow:SelectTab("planner")`. Empty state: "No knowledge data yet". Refresh on `FS_ALTS_CHANGED` (`MainWindow:RefreshTab("dashboard")`).

- [ ] **Step 4: Run** — `busted` → PASS. In game: the widget shows on the Dashboard and updates after completing a weekly quest.

- [ ] **Step 5: Commit**

```bash
git add UI/AltsDashboard.lua tests/ui/dashboard_widgets_spec.lua FabricationStation.toc
git commit -m "feat: add knowledge Dashboard widget"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 15 (register widgets from a small core registrar in OnInitialize like phase 2's UI/OrdersWidgets.lua; `Dashboard.SetLines` takes plain strings, not two-column pairs; widget order 65 is free; TOC: UI\AltsDashboard.lua at the end, after UI\AltsTooltips.lua).
- Use PlannerView.KnowledgeLines / ConcentrationLines (Task 12): honour their `max` contract and show KnowledgeLines' `.tooltip` (Task 12 note) via the widget's tooltip hook as OrdersWidgets does.
- States: Alts off → "Alts is turned off"; Planner off where relevant; hidden characters excluded (review focus 4); unknown knowledge "?" never "0 left"; concentration nil "—"/capped "Full"; outdated marker from the Knowledge table's own build only (CharactersView.CurrentDataNote / U.knowledgeBuild — Task 14 rule).
- Refresh: FS_ALTS_CHANGED (Alts announces on enable/disable) → Dashboard refresh debounced + Wrapped; no work while the Dashboard isn't shown if Dashboard supports that; OnDisable cleanup.
- Task 14 minors folded in: Planner tab bottom-anchored message (UI/Tabs/Planner.lua ~693) gets SetWordWrap(false) + hover tooltip; contract's ViewUtil helper list adds knowledgeBuild()/clientBuild(); the section builder's names loop uses a `false` sentinel for uncached items so duplicates don't repeat the lookup.
