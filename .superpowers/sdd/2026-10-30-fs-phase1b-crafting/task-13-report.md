# Task 13 report: Dashboard tab with RegisterWidget and phase-1 widgets

Status: DONE (one concern, see below). Commit: see `git log -1` (feat: add Dashboard tab with widget registry and phase-1 widgets).

## Built
- `UI/Tabs/Dashboard.lua`: module `Dashboard` (coreModule), registers tab `dashboard` (label Dashboard, order 10, phase 1) in OnEnable.
  - `RegisterWidget(id, def)` (stores `def.id`, same id replaces and keeps its place, invalid def returns false + LogError; a widget registered after the tab was built is built and refreshed at once), `GetWidgets()`, `BuildAll(container)`, plus `RefreshAll()`, `GetBuiltFrames()`, `GetScrollFrame()` and `Dashboard.SetLines(frame, lines)` (shared helper for widget refresh functions: pooled font strings, sizes the frame).
  - Grid: scroll frame (mouse wheel, no template) holding a two-column grid anchored to the child's TOP; row height = taller widget; relaid out after every refresh pass (widget heights follow their line count), so many alts never overflow the window.
  - Isolation: widget build/refresh run via `SafeCall("Dashboard:<id>", ...)` (non-module source: logs only, module stays on). A failed build sets `frame.errorText = "widget failed"` (and a red label), the widget is not refreshed again; a failed refresh sets it too and a later good refresh clears it.
  - Pure models: `TopCraftsModel`, `QueueSummaryModel`, `ConcentrationModel` as in the brief.
  - Widgets: `topCrafts` (10), `queueSummary` (20), `concentration` (30).
  - Refresh: FS_RECIPES_CHANGED / FS_QUEUE_CHANGED / FS_DATA_CHANGED -> `ns.FS:Debounce("dashboard.refresh", 0.5, ...)` -> `MainWindow:RefreshTab("dashboard")` (only when selected and shown); cancelled and unregistered on disable.
- TOC: `UI\Tabs\Dashboard.lua` between MainWindow and Settings.
- Tests: `tests/ui/dashboard_spec.lua` (30 specs).
- Also touched: `tests/helpers/wow_stubs.lua` (frame stub gets `CreateTexture`; unknown methods return nil, so the widget background needed it) and `tests/ui/settings_spec.lua` (one assertion `#MW:GetTabs()` 1 -> 2, now that the dashboard tab exists).

## Display rules (contract, 1b Task 10 note)
- profit nil -> "no price" (never 0g, no age shown); profit present + `flags.noPrice` -> profit + "some prices missing"; `flags.estimated` -> "estimate"; price age shown as "price 2d old" from `priceAgeDays` (stale prices add ", stale" in red). Queue cost shows "prices Xh old" from `Prices:GetLastUpdate`, or "unknown (some prices missing)" when `totalCost` is nil.
- Top crafts takes `GetRanked({ sortBy = "profit" })` in ranking order (no re-sort, so noPrice-with-profit results stay with the unpriced ones, as the contract says) and shows the first 10. No `onlyProfitable` filter: loss-makers and unpriced rows appear when fewer than 10 are profitable.
- Concentration: every non-dropped profession with a snapshot of every character, projected to now; `regenPerSec = (Project(now+3600) - Project(now)) / 3600`; "full" when at max, "full in 3h 20m", "full in ?" when no rate.

## TDD
- RED: `busted tests/ui/dashboard_spec.lua` before the module/TOC entry: `lastFile not found in FabricationStation.toc: UI/Tabs/Dashboard.lua` (error in before_each).
- GREEN: `busted tests/ui/dashboard_spec.lua` -> `30 successes / 0 failures / 0 errors`.
- Full: `busted` -> `834 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` -> `0 warnings / 0 errors in 78 files`.
- Bug found by tests: with RECIPES/DATA messages, Queue's own 0.5 s recompute re-sends FS_QUEUE_CHANGED, so the dashboard refreshes again (correct behaviour); the debounce spec silences Queue's listeners to stay deterministic.

## Self-review
- No Blizzard frame is written to; only own frames, `SetScript` on own scroll frame, `HookScript` for size.
- No global added to luacheck.
- Stub frames fire no OnShow/OnHide: specs call RefreshAll/MW:Show directly.

## Concerns
- Not verified in the real client (no game here): scroll frame sizing (child width follows OnSizeChanged of the scroll frame), the line text width/truncation (word wrap off, profit is first on each line), and there is no visible scrollbar (wheel only).
- Concentration "full in" only updates on refresh (tab select or the three messages), not by timer.
- Empty GameData means top crafts will mostly show estimates until real data is stamped.

## Fix round 1
Changes (UI/Tabs/Dashboard.lua):
1. Top crafts calls `GetRanked({ sortBy = "profit", onlyProfitable = true })`; empty state is "Scanning recipes..." only while `IsScanning()`, else "No profitable crafts right now - check prices (Auctionator scan) or wait for the next scan." (em dash in the file). Specs: filter captured and asserted; noPrice/nil-profit rows removed from the widget spec (comment notes TopCraftsModel keeps those branches for other callers); empty and scanning states.
2. Concentration rate now comes from the snapshot's `perCycle / cycleSeconds`; the measured-from-projection rate is only the fallback when those are missing. Spec: 995/1000 at 1 per 360 s shows "full in 30m".
3. Late `RegisterWidget` no longer builds/refreshes: it asks `MainWindow:RefreshTab("dashboard")` (no-op unless selected and shown); `RefreshAll` first builds/rebuilds any widget whose frame is not from its current def (`grid.builtDefs`), and the layout skips widgets without frames. Specs: not shown -> built by the next `RefreshAll`; another tab selected -> built on returning to the dashboard; shown -> built and refreshed at once, replacement in place.
4. Added "does not refresh while another tab is selected" (refreshes on return); the closed-window spec was renamed accordingly.

Command: `busted tests/ui/dashboard_spec.lua` -> `36 successes / 0 failures / 0 errors / 0 pending`.
Full: `busted` and `luacheck .` results below.
840 successes / 0 failures / 0 errors / 0 pending : 4.966166 seconds
Total: [0m[0m[1m0[0m warnings / [0m[0m[1m0[0m errors in 78 files
