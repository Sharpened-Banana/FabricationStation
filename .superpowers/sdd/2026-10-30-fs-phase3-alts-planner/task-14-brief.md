### Task 14: Planner tab

**Files:**
- Create: `UI/Tabs/Planner.lua`
- Modify: `FabricationStation.toc` (between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`, after `UI/Tabs/Characters.lua`)
- Test: `tests/ui/planner_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab` (at file load), `MainWindow:RefreshTab(id)`, `Planner:GetKnowledgeChecklist/GetSchedule/GetCapWarnings/GetSpecAdvice/GetMissingRecipes/GameDataBuild`, `Alts:GetOverview`, `Queue:Add(entry)` (1b `QueueEntry` fields), `ns.UI.FormatMoney`.
- Produces: tab `"planner"` `{ label = "Planner", icon = "Interface\\Icons\\INV_Misc_Note_01", order = 80, phase = 3, build, refresh }`.

- [ ] **Step 1: Write the failing test** — same shape as Task 13: `env.registered.tabs.planner` has label `"Planner"`, order `80`, phase `3`.

- [ ] **Step 2: Run** — `busted tests/ui/planner_tab_spec.lua` → FAIL.

- [ ] **Step 3: Implement `build(container)`** with four sub-sections selected by a button row (Knowledge, Concentration, Spec advice, Missing recipes), last choice remembered in `settings.planner.section`.
  - **Knowledge:** ExpandGrid of checklist rows; columns Character, Profession, Weekly Quest, Treatise, Treasures, Drops, Darkmoon, One-time, First crafts, Left; each category cell `earned/total` with a check icon when done, "closed" for Darkmoon closed, "?" for unknown; expanded detail lists each source with item name (`C_Item.GetItemNameByID(itemID)`), points, hint. Footer: "Knowledge data: build <GameDataBuild()> · Weekly reset in <FormatDuration>" ("not generated" when `ns.GameData.Status(clientBuild).missing`, "outdated" when it lists `Knowledge` in `mismatched` or `outdated` is true — 1a's status semantics) (reset from `C_DateAndTime.GetSecondsUntilWeeklyReset()` when available).
  - **Concentration:** cap-warning banner rows (red "capped", orange "soon") then schedule rows: Character, Profession, Recipe, Crafts, Concentration, Gain (`FormatMoney(expectedGain)`), Gold/conc, Caps in. Each row has "Queue" → `Queue:Add({recipeID, quantity = crafts, charKey, useConcentration = true})` (a click; no automatic queueing).
  - **Spec advice:** character + profession dropdowns (from overview); rows: Path, Rank `rank/maxRank`, Points, Gain (`FormatMoney`), Per point, "Affordable" tag; label "Estimate from your top <specTopRecipes> profitable recipes". Empty state: "Open this profession's specializations on <char> to load spec data".
  - **Missing recipes:** character + profession dropdowns; rows: Recipe name, Source text (`text` or kind label: `auto` → "Learned automatically", `item` → "Recipe item: <item name>", `unknown` → "Unknown — open the profession on any character to load sources").
  - On `FS_ALTS_CHANGED` / `FS_RECIPES_CHANGED` the Planner module calls `MainWindow:RefreshTab("planner")` (runs only while shown).

- [ ] **Step 4: Run** — `busted` → PASS. In game: each section renders; Queue button adds the entry (check Queue tab); Darkmoon shows "closed" outside the faire week.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Planner.lua tests/ui/planner_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Planner tab with knowledge, concentration, spec and recipe sections"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 14 (core registrar in OnInitialize; settings_spec tab count 8→9; load_all_spec; TOC after Characters; Task 14 only calls Queue:Add — no protected calls).
- Use Task 12's ExpandGrid + PlannerView (statuses already worded) and the Task 13 tab patterns (UI/Tabs/Characters.lua: debounced Wrapped RefreshTab on FS_ALTS_CHANGED/FS_RECIPES_CHANGED, tick cancelled on OnHide, listeners only while needed, Alts-off state, outdated-data marker region, 516 px placement specs that assert anchors/widths, not just text).
- Planner getters return `rows, status` (Tasks 9-11); the tab checks `Planner:IsEnabled()` itself; render each status with PlannerView's message (off/hidden/noProfession/noData/notScanned/noSpec/noRecipes).
- Task 11 carry (binding): compute GetSpecAdvice lazily — only while the Spec advice section is shown and only for the selected character + line; recompute via Debounce+Wrap on messages, never synchronously inside a handler, never looping all characters×lines. nil gain → "?" ; all-nil → PlannerView's "Spec effect data not in this GameData build" note.
- "Add to Queue" for schedule rows (if the plan has it) goes through Queue:Add with the row's recipeID/charKey/crafts and useConcentration; show the result in a status line that leads with the key word.
- Task 13 minors folded in (UI/Tabs/Characters.lua): rename the marker label to "Old data" with tooltip first line "Game data build <X> is outdated" (no "Outdated: … (outdated)" repetition); the Alts-off branch also clears `notice`. Apply the same marker wording on the Planner tab.
