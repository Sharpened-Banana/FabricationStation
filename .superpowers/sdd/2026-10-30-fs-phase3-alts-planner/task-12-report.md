# Task 12 report: ExpandGrid widget and Characters/Planner view models

Status: DONE_WITH_CONCERNS (in-game visual check deferred to the checklist; plan deviations listed below)
BASE 10ca013 -> commit 1b3a8f4 `feat: add expandable grid widget and Characters/Planner view models`

## What I built

- `UI/Widgets/ExpandGrid.lua` (`ns.UI.ExpandGrid`)
  - Pure `Layout(rows, expanded, rowHeight)` (the plan's test, verbatim). A detail entry is added only for an expanded row with a positive `detailHeight`.
  - Pure `ColumnLayout(columns, width, { hideOrder, minFlex = 120 })` hides columns by priority. A hide step can be one key or a group of keys hidden together. The function returns `{ hidden, flex }`, and an unknown width hides nothing.
  - `PlaceCells` anchors the columns before the flexible one from the left edge, the columns after it from the right edge, and the flexible column to both edges. It is the same scheme as Orders.lua.
  - `New(parent, columns, opts)` builds a plain ScrollFrame with pooled frames, as preflight row 19 requires. Rows and details come from two separate pools, and only the entries in view are bound. Rows support variable heights. The header row shows the column labels. Clicking a row toggles it; a row without a detail is left alone. The grid also has a hover tooltip (`SetTooltip`) and mouse-wheel scrolling. On the grid's and the parent's `OnSizeChanged` it lays the columns out again, which re-anchors the header and every pooled row. All handlers go through `ns.FS:Wrap(opts.source)`. Renderers get `(frame, row, layout)`, so a renderer can show "+N" for hidden columns.
- `UI/Tabs/CharactersView.lua` (`ns.UI.CharactersView`) contains:
  - `FormatDuration`, `KnowledgeCell`, `KnowledgeBreakdown` and `Row` (the plan shape plus `charKey`, `class`, `isCurrent`, `hidden` and `older`).
  - `COLUMNS`, `HIDE_ORDER` and `Layout(width)` (preflight row 20). The Character column gets 128 px at 516 px (Profession 1, Concentration 1, KP 1 and Age stay) and 140 px at 716 px (Spec 1 and Gold come back).
  - `MoreCount` and `CellTexts`: class colour via `RAID_CLASS_COLORS`, "• " for the current character, "+N" on the last visible profession slot, red for urgent concentration, orange for a stale age.
  - `TooltipLines`: every value, including those in hidden columns.
  - `Header` (Task 7 carry): Characters, gold sum ("+" when some gold is unknown), knowledge sum ("N+?" or "?"), and the "data build X (outdated)" marker in both the text and the tooltip.
  - `DataBuildNote` and `CurrentDataNote`, and `OffText()` ("Alts is turned off").
- `UI/Tabs/PlannerView.lua` (`ns.UI.PlannerView`) contains:
  - `ConcentrationLines`, which sorts by fullAt. "Full", ">14d" and "—" are shown, and the list ends with a "+K more" line when it is capped.
  - `KnowledgeLines`: Total first, "?" rows for unknown data, done rows left out, the outdated marker on Total, and the "+K more" cap.
  - `StatusText`: one message per status (off naming Alts or Recipes, plannerOff, hidden, noProfession, noData, notScanned, noSpec, noRecipes).
  - `EmptyText` per section.
  - `SpecAdvice` (Task 11 carry): nil gain shows "?", unknown affordability gets no tag, and when every gain is nil the view says "Spec effect data not in this GameData build (<build>|not generated)". It never calls GetSpecAdvice.
  - `SourceText`.
  - The knowledge grid: `KNOWLEDGE_COLUMNS`, `KNOWLEDGE_HIDE_ORDER`, `KnowledgeLayout` (Character gets 156 px at 516 px), `KnowledgeCells` ("e/t", "closed", "?", "—", done flags) and `KnowledgeTooltipLines`.
- `FabricationStation.toc`: the three files are added after `UI\Tabs\Ledger.lua` (preflight row 3).
- `.luacheckrc`: `RAID_CLASS_COLORS` only. `ScrollUtil` was already present, and `CreateScrollBoxListLinearView`/`CreateDataProvider` were dropped per preflight rows 15 and 19.
- Contract: added a `[phase 3 Task 12]` bullet covering all three namespaces.
- In-game checklist: added one T12 line (grid behaviour at the minimum width, "+1", glyph rendering), to check once Tasks 13 and 14 use the grid.

## Tests

- `tests/ui/expand_grid_spec.lua` (14 specs):
  - Layout, including the plan test.
  - ColumnLayout: priority, groups, unknown width.
  - Grid: header labels, default and custom renderers, toggling the detail and how it shifts the rows below, no toggle without a detail, expansions kept across SetRows, virtualization while scrolling, both-edge anchors at 516 px with hide and restore on size change, tooltip, error isolation.
  - **The Characters columns at 516 px**: exact anchors and widths, then 716 px.
- `tests/ui/views_spec.lua` (31 specs):
  - All 7 plan tests. "Row for Aria" was adjusted per preflight row 33, see the deviations.
  - Unknown values (dash, "?", "--"), ">14d", capWarnHours urgency, cooldown states.
  - KnowledgeBreakdown, Layout, CellTexts with "+N", class colour, tooltips.
  - Header partial and unknown cases, and the outdated marker (`GetBuildInfo` 70700).
  - ConcentrationLines: unknown last, "+K more", time left from fullAt − now.
  - KnowledgeLines: "?", done rows omitted, cap, outdated marker.
  - Every status message unique, off naming Alts or Recipes.
  - SpecAdvice for "?", all-nil gains and statuses; SourceText; EmptyText; KnowledgeCells; KnowledgeLayout at 516 px; knowledge tooltip.

### TDD evidence

RED (before any implementation file existed):
```
$ busted tests/ui/expand_grid_spec.lua tests/ui/views_spec.lua
./tests/helpers/phase2.lua:74: failed to load UI/Widgets/ExpandGrid.lua: cannot open UI/Widgets/ExpandGrid.lua: No such file or directory
0 successes / 0 failures / 0 errors... -> 0 successes / 0 failures / 45 errors / 0 pending
```
First GREEN attempt: 43/2. Both failures were arithmetic slips in my own expectations: 400 px leaves 126 px, so nothing hides, and 500 copper is "5s 0c". I fixed the expectations, not the code:
```
$ busted tests/ui/expand_grid_spec.lua tests/ui/views_spec.lua
45 successes / 0 failures / 0 errors / 0 pending
```
Final:
```
$ busted
2135 successes / 0 failures / 0 errors / 0 pending
$ luacheck .
Total: 0 warnings / 0 errors in 150 files
```
The suite went from 2090 to 2135 specs.

## Deviations from the plan text (preflight and orchestrator rulings win)

1. **Plan test "Row for Aria"**: Aria is the logged-in character, so per preflight row 33 `age = "online"` and `staleAge = false`, where the plan test expected "1h 0m". Non-current ages are tested on Cato ("2h 0m") and Bren ("10d 0h", stale).
2. **ExpandGrid** is a plain pooled ScrollFrame, not a ScrollBox (preflight row 19). Renderers take an extra third argument, `layout`. Additions: `ColumnLayout`, `PlaceCells`, `SetTooltip`, `IsExpanded`, `ApplyLayout`, `Refresh`.
3. **Concentration with a known value that is not full within PlanCalc's 14-day horizon** (`secondsToFull` nil) shows "… · >14d" rather than "—". "—" stays reserved for unknown concentration (design rule 6).
4. **Cooldowns**: a cooldown with a charge left counts as ready. When some are ready and some pending, the cell shows "N · K ready" instead of the soonest pending time, because the plan's rule would hide the ready ones.
5. **KnowledgeLines**:
   - Rows with 0 left are omitted.
   - Rows whose summary is not "ok" are listed as "? KP" and make the total "N+? KP".
   - The `max` limit counts the Total line, and the last line is "+K more" when rows are cut.
6. Views spell out every status message the brief listed, plus texts for those it did not word:
   - hidden: "Hidden: <char> is hidden on the Characters tab"
   - noSpec: the plan's Task 14 text
   - noRecipes: "No profitable recipes for <char> in this profession yet: check prices or open the profession"

## Self-review findings (fixed before commit)

- `ConcentrationLines` did not use `now` (luacheck). It now computes the time left as `fullAt − now`, and a spec covers it.
- `Toggle` on a row without a detail recorded an expansion that could surprise later. It is now a no-op, and a spec covers it.

## Concerns / notes for Tasks 13-15

- No tab uses the grid yet. The real-client behaviour (Button default click registration, OnSizeChanged firing through anchors, font glyphs for "·", "—" and "•") is unverified, and the T12 checklist line covers it.
- `ExpandGrid.New` hooks `OnSizeChanged` on its parent. Several grids in one container (the Planner sections) each hook it, which is cheap: a relayout runs only when the set of hidden columns changes.
- Task 13:
  - The Characters header comes from `CharactersView.Header(GetOverview())`.
  - The detail renderer can use `KnowledgeBreakdown`, `row.older` and the profession data.
  - Spanning the empty text across the profession columns is left to the tab; `CellTexts` puts it in slot 1.
- Task 14:
  - Use `PlannerView.StatusText` with `{ recipes = true }` for GetSchedule and GetSpecAdvice.
  - The schedule rows' cells (the recipe name lookup) are not modelled here.
  - `SpecAdvice` must be computed lazily by the tab.
- Task 15: `KnowledgeLines` returns `{left, right}` pairs, so `SetLines` needs one string per line.
- `.superpowers/` appears to be untracked, so the checklist addition is not in the commit.

---

# Fix round 1 (commit e9981b6, on 1b3a8f4)

Status: DONE. Every ruling is addressed. "Regen rate unknown" (Minor 4) is deferred as instructed.

## Changes per ruling

1. **"+N" survives truncation** (`UI/Widgets/ExpandGrid.lua`, `UI/Tabs/CharactersView.lua`):
   - A column flagged `badge = true` (Profession 1/2) is now a slot frame placed like any cell. It holds the label `frame.cells[key]` and a badge `frame.badges[key]` anchored to the slot's RIGHT edge.
   - `ExpandGrid.SetBadge(frame, key, text)` anchors the label's RIGHT to the badge's LEFT, 2 px apart (0 px when the badge is empty).
   - `CharactersView.CellTexts` now returns `cells, badges`. The label no longer carries "+N".
   - The default renderer applies `row.badges`, and `bind_row` clears every badge before rendering.
2. **Details at narrow width**:
   - `detailHeight` may be `fn(row, width)`, and `Layout` gained a 4th argument, `width`.
   - New `ExpandGrid.WrappedHeight(lines, width, opts)` estimates the wrapped text height: 6 px per character, 14 px per line, a 28 px inset.
   - `ApplyLayout` re-runs `Refresh` whenever the width changes, even when the hidden-column set does not.
   - Detail frames call `SetClipsChildren(true)`, and their text has `SetWordWrap(true)`.
3. **Ages use `ns.UI.FormatAge`**:
   - Bren "10d", Cato "2h", unknown "never". The tooltip reads "Last seen: 10d ago (stale)" or "Last seen: never (stale)".
   - FormatDuration stays for time to full and cooldowns.
   - The plan tests were adapted as ruled.
4. `bind_detail` clears `frame.text` before calling the renderer.
5. **`capped`**:
   - It never returns more than `max` lines.
   - When only one line fits, that line is "+K more" alone; K counts the rows not shown.
   - `max < 1` gives `{}`.
   - This applies to both ConcentrationLines and KnowledgeLines.
6. The row tooltip adds ", next in <duration>" for the soonest pending cooldown, unless the cell already ends with that duration ("1 · 2h 0m"), to avoid saying it twice. A new `Row` field, `cdsNext`, supports this.
7. **Narrow cells and tooltips**:
   - The Gold cell uses `goldShort`. That comes from the new `ViewUtil.compactMoney`, which calls OrdersPanel's CompactMoney at call time and falls back to FormatMoney. The tooltip keeps the full value.
   - The row tooltip shows the outdated-data marker after "Knowledge left this week".
   - The KnowledgeLines Total becomes `"5 KP (outdated)"`, with `tooltip = "Knowledge data build 70575 (outdated): …"` on that line.
   - ExpandGrid header labels get hover frames (`grid.headerHits`) that show `col.tooltip` (else the label). They hide together with their column. Tooltips were added for the Characters columns KP, Concentration, Spec, Cooldowns, Profession and Age, and for the knowledge grid's Quest, Treatise, Treasure, Drops, Darkmoon, One-time, First and Left.
8. **Duplication**:
   - New `UI/Tabs/ViewUtil.lua` (`ns.UI.ViewUtil`): `EM_DASH`, `DOT`, `finite`, `whole`, `color`, `module`, `compactMoney`. It is in the TOC after ExpandGrid, and both view files use it.
   - Core gained `FS:GameDataStatus() -> status, clientBuild`. `GameDataStatusText` now uses it (wording unchanged; the core and diagnostics specs still pass), and `CharactersView.CurrentDataNote` uses it instead of reading GetBuildInfo.

Contract: the Task 12 bullet was updated in place, with the ViewUtil and `FS:GameDataStatus` additions marked "[Task 12 fix round 1]".

## Tests

New or changed specs:
- `tests/ui/expand_grid_spec.lua`:
  - Characters 516 px anchors now go through the profession slot frame.
  - New: "+1" badge visible with "Leatherworking 100/100" at 516 px (badge RIGHT on the slot's RIGHT, label RIGHT on the badge's LEFT −2, slot 130 px; cleared again at 1400 px).
  - New: 516 px detail with KnowledgeBreakdown-length lines, also covering clipping. The detail height is 32 px at 1400 and 60 px at 516 with the same hidden set; the row below shifts; `SetClipsChildren(true)` is recorded.
  - New: reused detail frame (expand k2 and k4, collapse k2: the reused frame shows k4 with empty text).
  - New: header hover tooltip.
- `tests/ui/views_spec.lua`:
  - FormatAge ages: Bren "10d", Cato "2h", "never".
  - goldShort "1,234g"; the compact Gold cell; `CellTexts` badges.
  - Tooltip checks: full gold, "next in", the outdated marker on the knowledge count.
  - Capped lines with max 1 and max 0 for both line kinds.
  - The "(outdated)" Total with its tooltip.
  - The spec world also loads `UI/OrdersPanel.lua`, which works in phase3_env.

RED: I ran the new specs against the pre-fix files from HEAD:
```
$ (HEAD UI/Widgets/ExpandGrid.lua) busted tests/ui/expand_grid_spec.lua
13 successes / 2 failures / 3 errors   (specs @228 slots, @254 badge, @280 detail width, @314 reused detail, @327 header tooltip)
$ (HEAD CharactersView.lua + PlannerView.lua) busted tests/ui/views_spec.lua
22 successes / 9 failures / 0 errors
```
GREEN:
```
$ busted tests/ui/expand_grid_spec.lua tests/ui/views_spec.lua
18 successes / 0 failures / 0 errors ; 31 successes / 0 failures / 0 errors
$ busted
2139 successes / 0 failures / 0 errors / 0 pending
$ luacheck .
Total: 0 warnings / 0 errors in 151 files
```

## Notes

- `WrappedHeight` is an estimate (6 px per character for GameFontHighlightSmall, on the generous side), and clipping covers the remainder. The T12 in-game checklist line covers checking it in the client.
- Changing `CellTexts` to return `cells, badges` changes the API Task 13 consumes: a row renderer must call `ExpandGrid.SetBadge`, or pass `badges` to the default renderer.
