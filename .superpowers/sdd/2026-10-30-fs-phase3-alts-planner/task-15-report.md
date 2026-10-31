# Task 15 report: Dashboard widgets

Status: DONE. BASE aa2226f. Commits:
- 396dda9 feat: add knowledge Dashboard widget
- ab60f47 fix: keep the Planner message line on one line and look each item name up once

## What was built

`UI/AltsDashboard.lua` is new. It holds the core registrar module `AltsWidgets` (`coreModule = true`) and the namespace `ns.UI.AltsDashboard`.
- **Registration:** `OnInitialize` registers `"altsKnowledge"` `{ order = 65, title = "Knowledge left this week", build, refresh }` through `Dashboard:RegisterWidget`. This follows preflight row 21: a core registrar in OnInitialize, not `Alts:OnEnable`. There is no `altsConcentration` widget.
- **build(frame):** turns on `EnableMouse`, then hooks three scripts: OnEnter shows a tooltip, OnLeave hides it, and OnMouseUp with LeftButton calls `MainWindow:SelectTab("planner")`. It then calls `SetLines(frame, {})`. Errors are logged under `"Dashboard:altsKnowledge"`, as in OrdersWidgets.
- **refresh(frame):** calls `Dashboard.SetLines(frame, CurrentModel(now).lines)`. These are single strings, not two-column pairs (preflight row 21). The count comes first, so a line cut at the widget's narrow width still shows it:
  - the total: `"Total: <right>"`, orange when it carries the " (outdated)" note
  - each row: `"<n> KP  <charKey> <profession>"`, or `"? KP  ..."` (dim) when unknown
  - the last line when rows are left out: `"+K more"`
- **Line cap:** `KnowledgeLines(rows, 6)` honours the max contract.
- **Tooltip:** lists every line (`KnowledgeLines` with no max), then the total's `.tooltip` (the outdated reason), then "Click to open the Planner".
- **States:**
  - The Planner module missing or off → "Planner is turned off". This follows the Planner tab, which checks Planner first.
  - Checklist status `"off"` → "Alts is turned off" (both through `PlannerView.StatusText`), with "Turn it on in Settings > Modules" under it.
  - No rows → "No knowledge data yet" + "Open a Midnight profession on each character".
  - Every row `"noData"` → "No knowledge data yet" + "This GameData build has no knowledge sources for your professions".
  - The last case is what the shipped empty Knowledge table produces. Rows whose status is `"unknown"` still show as "? KP", never "0 KP".
- **Hidden characters:** they are excluded because `GetKnowledgeChecklist` reads `Alts:GetOverview()`.
- **Outdated marker:** comes from `CharactersView.CurrentDataNote`, which uses the Knowledge table's own build. A spec checks that defining another table at an older build does not mark it.
- **Refresh:** `FS_ALTS_CHANGED` triggers a 0.5 s Debounce (`altsWidgets.refresh`, wrapped with the log-only source `"AltsWidgets:Refresh"`), then `MainWindow:RefreshTab("dashboard")`, which does nothing unless the Dashboard is shown. Alts already announces when it is turned on or off. OnDisable unregisters the message and cancels the debounce.

TOC: `UI\AltsDashboard.lua` is the last line, after `UI\AltsTooltips.lua`.

Task 14 follow-ups:
- **Planner tab message line:** `show_empty` now calls `SetWordWrap(not below)`. The bottom-anchored line (above the footer) does not wrap and gets a hover area `view.emptyHit` (the `hover_area` helper) that shows the whole message. The top-anchored message still wraps, and its hover area is hidden.
- **Section builder names loop:** stores `item_name(itemID) or false`, so a repeated uncached item is looked up once per row. `KnowledgeDetailLines` treats false like a missing name and shows "item:<id>". The doc comment is updated.
- **Contract:**
  - The ViewUtil helper list now includes `knowledgeBuild()` and `clientBuild()`.
  - The Dashboard entry lists `altsKnowledge` 65 and the `AltsWidgets` refresh.
  - The core-module list now includes `AltsWidgets`.
  - New `[phase 3 Task 15]` entry.
  - The Planner tab entry notes the message line and the `false` names.

Other test-list updates: `load_all_spec` now includes `AltsWidgets` in its module list. `toc_spec` has a new spec checking that AltsDashboard is last and comes after AltsTooltips.

## Tests

New `tests/ui/dashboard_widgets_spec.lua` (17 specs):
- order and title, no `altsConcentration`, core registrar, build with no lines
- total, then rows by most points left
- "? KP" (never 0) and "2+?" total
- hidden character left out
- 6-line cap with "+4 more", and a tooltip listing all 8 rows
- outdated total with the reason in the tooltip
- outdated marker from the Knowledge build only
- no rows, and no Knowledge data
- Alts off, Planner off
- left and right click
- tooltip show and hide
- debounced refresh on a burst, and nothing after Disable
- a whole-addon boot: widget order `topCrafts, queueSummary, concentration, openOrders, goldThisWeek, altsKnowledge`, filled through the real Dashboard with no errors and no diagnostics

`planner_tab_spec` has 2 new specs: the message line (no wrap, hover tooltip, rewraps under the header) and the one lookup per repeated item. `toc_spec` has 1 new spec.

Full suite: `busted` → `2234 successes / 0 failures / 0 errors / 0 pending` (baseline 2214, +20). `luacheck .` → `0 warnings / 0 errors in 157 files`.

## TDD evidence

- RED: `busted tests/ui/dashboard_widgets_spec.lua` → `0 successes / 1 failure / 15 errors`. The cause was `failed to load UI/AltsDashboard.lua: cannot open UI/AltsDashboard.lua`, and the whole-addon widget list did not include `altsKnowledge`.
- GREEN: after the implementation and TOC line → `12 successes / 4 failures`. The 4 failures were my wrong guesses about the fixture: Bren is "ok" with 3 KP, and the profession names are "Blacksmithing"/"Herbalism", matching views_spec. I corrected the expectations to the fixture and added an explicit unknown case by setting Bren's `knowledgeWeekly = {}`. Result: `16 successes / 0 failures`, then 17 with the build-marker spec.
- Planner message: RED `38 successes / 1 failure` (`wraps[#wraps]` was nil because SetWordWrap was never called). GREEN `39 successes`.
- Names sentinel: GREEN `40 successes`. With `or false` temporarily removed, RED `39 successes / 1 failure` (`Expected 1, passed 2` lookups). With it restored, GREEN `40 successes`.

## Files changed

- UI/AltsDashboard.lua (new)
- tests/ui/dashboard_widgets_spec.lua (new)
- FabricationStation.toc
- tests/tooling/toc_spec.lua, tests/integration/load_all_spec.lua
- UI/Tabs/Planner.lua, tests/ui/planner_tab_spec.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- .superpowers/sdd/.../ingame-checklist.md (4 T15 lines; the file is untracked)

## Self-review findings / deviations

- **Where the brief and the plan differ:**
  - The plan builds "6 two-column font strings" and registers in `Alts:OnEnable`. As preflight row 21 rules, the widget uses SetLines strings and a core registrar in OnInitialize.
  - The Step 1 test shape (`env.registered.widgets`) is used exactly.
- **Off-state order:** "Planner is turned off" is checked before Alts. The widget opens the Planner tab, and that tab shows the same message first.
- **`ConcentrationLines` is unused:** there is no concentration widget (plan and brief), so it is not used here.
- **No saved-data writer:** the widget only reads, so no dbIsNewer spec is needed.
- **Contract hunks:** the contract edits for the Task 14 follow-ups went into the feat commit, because both touch the same file.

## Concerns

- **Not checked in game:** the click target (OnMouseUp on the Dashboard's widget frame, which is mouse-enabled) and the widths are untested in game; they are on the in-game checklist. OrdersWidgets already uses the same EnableMouse plus HookScript pattern for its tooltip.
