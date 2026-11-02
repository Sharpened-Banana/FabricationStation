# Task 12 report: Ledger tab and Dashboard widgets

Status: DONE_WITH_CONCERNS
Commit: 1b374a1 feat: add Ledger tab and open-orders / gold-this-week dashboard widgets (BASE 2ea67ab)

## What I built

### UI/Tabs/Ledger.lua (module `LedgerTab`, coreModule)
- Registers tab `ledger` in `OnInitialize`: label "Ledger", order 60, phase 2, icon `Interface\Icons\INV_Misc_Coin_02`.
- One scrolling page, built as a pooled virtual list in a plain ScrollFrame (the Orders/Queue pattern). Each list item is a heading, a column header, a data row, a note or a spacer. A pooled row keeps one set of cells per section, created on first use and re-anchored only when that section's layout key changes. The sections, top to bottom:
  1. **Weekly profit (last 8 reset weeks)**: Week ("This week", then `%m-%d`), Income, Cost, Profit, and a note `"partial: <n> without cost basis"` (or "estimate"). An "8 weeks" total row follows. When the week boundary is unknown (`Weekly` returns `{}`), a note says so.
  2. **Profit by recipe**: `RecipeRows(Ledger:ByRecipe({}))`, best first. It is followed by an "Unattributed sales" row from `Ledger:Unattributed({})` when n > 0, so the rows add up to the weekly totals. Columns: Recipe (flex), Sales, Income, Cost, Profit, note ("partial" / "estimate").
  3. **Your tips by recipe and quality**: `BenchmarkRows(entries)`. Columns: Recipe, Q, Low (p25), Median, High (p75), n. If no row has enough samples, a note names the `benchmarkMinSamples` setting.
  4. **Entries (N)**: every entry from `Ledger:Query({})`, newest first, with Date, Type ("craft" / "sale" / "commission" / "recraft"), Item, Amount and Customer. The Customer column shows the customer, else the AH buyer, else "Patron" for an NPC order.
- An empty ledger shows "No sales recorded yet. ..." in the tab's empty line. A missing Ledger module shows "The Ledger is not available."
- Header line: "N entries, newest <age> ago". The status line reads "Read-only: saved data is from a newer addon version" while `dbIsNewer`, and "Ledger off: nothing new is recorded" while the Ledger module is disabled. Both lead with their key word, and a mouse area shows a tooltip with the full text and what to do. Without a status, the header gets the full width (the deferred Task 10 minor is applied here).
- Pure exports on `ns.UI.LedgerTab`: `RecipeRows`, `BenchmarkRows` (both per the brief), `Layout(section, width)`, `Model(ledger, now)`, `DisplayRows(model)`, `CellTexts(section, data)` and `TooltipLines(item)`. `LedgerTab:GetView()` gives test access.
- `OnEnable`: `LEDGER_CHANGED` triggers a debounced (0.5 s) `MainWindow:RefreshTab("ledger")`, wrapped as "LedgerTab". `GET_ITEM_INFO_RECEIVED` refreshes once a requested item name arrives (each item is asked for once per session, like the Orders tab). `OnDisable` unregisters everything and cancels the debounce. UI scripts are wrapped as "Tab:ledger".

### UI/OrdersWidgets.lua (module `OrdersWidgets`, coreModule)
- `OnInitialize` registers `openOrders` (order 40, "Open orders") and `goldThisWeek` (order 50, "Gold this week") through `Dashboard:RegisterWidget`. Lines are filled with 1b's `Dashboard.SetLines`.
- Pure exports: `OpenOrdersModel(snapshot, now)` and `GoldThisWeekModel(weekly)`, exactly per the brief (the brief's `assert.same` shapes hold). Additional helpers: `BestOrder`, `UnscoredReasons`, `OpenOrdersLines` and `GoldThisWeekLines`.
- **Open orders widget**: "No orders seen yet" before a board was seen. After that it shows "N open, M personal", then "Best score: [~]<money>" or "Best score: none". Next comes "Not scored: 1 recraft, 1 conc?, 1 no price"; these are the Task 4 markers, as the board shows them, never a generic "no price". The last line is "Seen <age> ago on <char>".
- **Gold this week widget**: shows "No sales recorded yet" when there are no sales or commissions at all. Otherwise it shows "Profit: <money> (partial)", "Income: <money>" and "Partial: N without cost basis". While `dbIsNewer`, the numbers still show and a "Read-only: ..." line is added; a disabled Ledger gets "Ledger off: ...".
- Each widget frame hooks OnEnter/OnLeave with a tooltip showing the title and every line in full, because widget lines can be cut at half the window width. These are HookScript calls on the Dashboard's own frame.
- `OnEnable`: `ORDERS_CHANGED` and `LEDGER_CHANGED` trigger a debounced (0.5 s) `MainWindow:RefreshTab("dashboard")`, wrapped as "OrdersWidgets". `OnDisable` unregisters and cancels the debounce.

### Other
- `FabricationStation.toc`: `UI\Tabs\Ledger.lua` after `UI\Tabs\Customers.lua`; `UI\OrdersWidgets.lua` after `UI\OrderAlert.lua`.
- `tests/ui/settings_spec.lua`: the tab count goes from 6 to 7, as Tasks 10 and 11 each did for their tabs.

## Width budget at the 516 px minimum (PAD 6, GAP 4)
| Section | Fixed columns | Flexible column at 516 | Hidden first when the flexible column < 120 |
|---|---|---|---|
| weekly | Week 64, Income 72, Cost 72, Profit 80 | Note 200 | Cost |
| recipe | Sales 36, Income 72, Cost 72, Profit 80, note 48 | Recipe 176 | Sales, then Cost |
| benchmark | Q 24, p25 64, Median 64, p75 64, n 32 | Recipe 236 | p25, then p75 |
| entry | Date 36, Type 64, Amount 72, Customer 90 | Item 226 | Customer, then Type |

The flexible column is anchored on both sides: the columns before it chain from the left edge, the ones after it from the right edge. The entry and weekly/recipe specs check the anchors and widths at 516 px, plus hiding and restoring on OnSizeChanged. Money cells use `OrdersPanel.CompactMoney`; `Sign == 0` (e.g. under a copper, shown as "0g") is grey. Row tooltips use full `FormatMoney`.

## Tests
New spec `tests/ui/ledger_tab_spec.lua` (29 specs):
- The brief's four specs, verbatim.
- Models:
  - phase, icon and coreModule for both modules
  - RecipeRows: unknown profit sorts last, ties go by recipeID, rows are copies
  - BenchmarkRows: sorted; recraft, nil-quality and non-commission entries are left out
  - Layout: every section at 516 px, and the hide order when narrower
  - Model: 8 weeks with a total, incomplete and estimated counts per week, recipe and unattributed totals
  - unknown week boundary
  - the order of the section headings
  - CellTexts: partial note, "~", unknown money is "?" (never 0g), recraft, Patron, buyer, damaged entries
  - TooltipLines: the partial explanation ("real profit may be lower", never "at least"), the recraft cost line, "Cost: unknown (no cost basis)"
- Frames:
  - the empty ledger message
  - sections render
  - entry row anchors and widths at 516 px, narrowing to 380 px and widening back
  - weekly and recipe anchors at 516 px, including the header row
  - row tooltip
  - the read-only notice leads with "Read-only" and has a tooltip; it clears afterwards
  - the Ledger-off notice
  - header and status widths with and without a status
  - one debounced refresh per burst, and no refreshes after Disable
  - item data requested once, and a refresh when it arrives
- Widgets (with the real Dashboard, BuildAll/RefreshAll):
  - order after the phase-1 widgets
  - the empty ledger message, then profit, income and partial lines
  - the read-only line, with the numbers still shown
  - open orders with the best score "~", the unscored reasons, the seen line, and "none"
  - widget tooltip
  - one debounced dashboard refresh per burst, and no refreshes after Disable

TDD evidence:
- RED: `busted tests/ui/ledger_tab_spec.lua` (before the implementation existed) gave
  `./tests/helpers/phase2.lua:74: failed to load UI/Tabs/Ledger.lua: cannot open UI/Tabs/Ledger.lua: No such file or directory`, the expected failure, in every block.
- First GREEN attempt: `26 successes / 3 failures`.
  - One failure was my own expectation: I chose to show "estimate" in the note column and the test said `""`. I updated the expectation.
  - Two were test filters: the Ledger tab specs also saw OrdersWidgets' "dashboard" refreshes, and vice versa. Each block now records only its own tab id.
- GREEN: `busted tests/ui/ledger_tab_spec.lua` → `29 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` → `1630 successes / 0 failures / 0 errors / 0 pending`. Before the settings_spec count fix it was 1629 / 1, with `settings_spec.lua:74` expecting 6 tabs and getting 7.
- `luacheck .` → `0 warnings / 0 errors in 120 files`.

## Self-review findings (fixed before commit)
- The header was always given 55% of the width; it now gets the full width when there is no status.
- The widget tooltip's SafeCall source was a made-up "Dashboard:orders". It is now "Dashboard:<widgetId>", the same source the Dashboard uses for that widget's build/refresh.
- The benchmark column labels were "Low 25%" / "High 25%", which is ambiguous. They are now "Low (p25)" / "High (p75)", and the tooltip says "A quarter of your tips were below/above X".
- I removed a redundant `n = nil` on weekly rows.

## Concerns / deviations
1. **"≥ / at least" is the wrong direction, so I used "partial" instead.** A sale or commission with no cost basis adds 0 to the cost (cost = nil). A cost flagged `incomplete` sums only the priced reagents. In both cases the real cost is higher than the shown cost, so the real profit is lower than the shown profit: the shown profit is an upper bound, not "at least". The orchestrator note allows "partial" or "≥". I show "partial: N without cost basis" or "partial", and the tooltip says "Their cost is not subtracted, so the real profit may be lower than shown." I never use "≥" or "at least". The comment at the top of `Modules/Ledger.lua` (lines 10-11: `So a profit with incomplete > 0 is "at least" a profit`) states the wrong direction. I left that file alone because it is out of scope; it is worth a one-line comment fix. Damaged amounts, which add 0 to income, are the rare exception that understates profit; "partial" covers both cases honestly.
2. **The four sections are stacked on one scrolling page.** The benchmark table comes before the entries list, not after it, so the possibly long entries list does not push it out of reach. Column headers scroll with their section; they are not pinned.
3. **Estimated counts** (`~` on aggregated cost and profit) are computed in the tab from `Query({})`, because `Weekly` and `ByRecipe` don't expose them. For the weekly rows this mirrors the Ledger's week-bucketing rule (a local `week_index`, plus `WEEK_SECONDS` duplicated from Ledger.lua). If the Ledger's rule changes, this needs updating too.
4. **BenchmarkRows ignores commissions with no numeric quality.** `Benchmark(recipeID, nil)` would merge every quality into an "all qualities" row that duplicates the per-quality rows.
5. The Open orders widget counts every order in the snapshot. It ignores the Orders filters, so hidden orders are included in "N open".
6. Not done here (Task 13's job per the plan): adding `LedgerTab` and `OrdersWidgets` to `tests/integration/load_all_spec.lua`. The full suite already loads the whole TOC cleanly.

# Fix round 1

Commit: 8e21db2 fix: count estimated costs in the Ledger, scope the recipe table to the shown weeks, and keep exact income unmarked

## Changes, by review item
1. **"~" on exact income.** In the entries list, `CellTexts` now calls `money_cell(data.amount, true, data.type == "craft" and data.estimated == true)`. A craft is the only entry whose amount is a cost; a sale or commission amount is exact gold. The entry tooltip already used the same rule. Spec: an estimated commission and an estimated sale both show "2g" with no "~", and a craft still shows "~-3g".
2. **Estimate count moved into the Ledger.**
   - `accumulate` (Modules/Ledger.lua) adds `if entry.estimated then totals.estimated = (totals.estimated or 0) + 1 end`, so the field stays nil when the count is zero and the existing verbatim shapes still pass.
   - The Weekly and ByRecipe doc comments document `estimated?`.
   - New Ledger spec: Weekly, ByRecipe and Unattributed counts; a week or recipe with no estimates has no field; craft entries are not counted.
   - In the tab, `WEEK_SECONDS`, `week_index` and the re-scan loop are deleted. `copy_totals` and `RecipeRows` carry `estimated`. The weekly total sums `count(w.estimated)`.
3. **Gold-this-week estimate.** `GoldThisWeekModel` adds `estimated = week.estimated` (nil when absent, so the brief's verbatim shape holds), and the profit line shows "~" when it is greater than 0. Spec: "Profit: ~<money>".
4. **Fix A: recipe table period.**
   - `Model` sets `since` = the oldest shown week's weekStart and passes `{ since = model.since }` to both `ByRecipe` and `Unattributed`.
   - Heading: "Profit by recipe (last 8 reset weeks)". When the week is unknown, `since` is nil (every entry) and the heading is "Profit by recipe (all recorded)".
   - The "none" note follows the period.
   - The header comment (old :6-7) now describes this.
   - Specs: a recipe sale and an unattributed sale older than 8 weeks are left out of both, with recipes + unattributed income = weekly total income; with the week unknown, an old entry is counted and the heading says "(all recorded)".
5. **Ledger.lua profit-rule comment** now reads "...is partial: the real cost is higher, so the real profit may be lower than shown."
6. **BenchmarkRows.** A recipe with no numeric-quality (non-recraft) commission at all gets one `Benchmark(recipeID, nil)` row. Its quality is nil, the cell shows "-", and the tooltip says "(all qualities)". Recipes that mix qualities still skip their quality-less commissions. Spec added; the existing spec now covers the mixed case.
7. **Open orders widget.** It now reads "N on the board, M personal", and the best score comes from `BestOrder(Orders:Filter(orders))`. "Not scored" still counts every order on the board. Spec: hiding personal orders moves the best score to the public order, and hiding both gives "Best score: none".
8. **Wording.** "with missing or partial cost" replaces "without cost basis" in the weekly note, the row tooltips, the widget and the header comments. The entry tooltip's "Cost: unknown (no cost basis)" was not in scope of the review item and was left as it is.
9. **Mutation spec.** The Model spec deep-copies `L:Query({})` (`P2.merge({}, live)`) before `Model`, then runs `DisplayRows`, `CellTexts` and `TooltipLines` on every entry. It compares each live row and the whole `Query` result against the copy afterwards.
10. **Polish.**
    - Benchmark-row anchor spec at 516 px: Recipe from the left; Q, p25, Median, p75 and n chained from the right edge; widths checked; flex = 236.
    - The recipe column is now "Count" (spec).
    - `has_sales` now makes a single `Query({})` pass instead of two typed Queries. Query still sorts once; the Ledger has no unsorted public reader, and reading `db.global.ledger.entries` directly would bypass the module.

## Tests
- RED: after the spec changes, `busted tests/ledger/ledger_spec.lua` gave `38 successes / 1 failure` (Weekly `estimated` nil, expected 2), and `busted tests/ui/ledger_tab_spec.lua` gave `21 successes / 12 failures`. The new benchmark-anchor spec passed at once; it adds coverage for the existing layout.
- GREEN: `busted tests/ui/ledger_tab_spec.lua tests/ledger` → `107 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` → `1635 successes / 0 failures / 0 errors / 0 pending`.
- `luacheck .` → `0 warnings / 0 errors in 120 files`.

# Fix round 2

Commit: a0135a9 test: make the Ledger tab mutation spec deep-copy the saved rows, and cover the since boundary
## Changes
1. **The mutation spec now actually checks for mutation.** `before = P2.merge(live, {})`; merge deep-copies its first argument, so `before[i]` is no longer the same table as `live[i]`.
   - RED probe A (as instructed): a temporary `for _, row in ipairs(entries) do row.estimated = 0 end` in `Tab.Model` → `32 successes / 1 failure`, failing at ledger_tab_spec.lua:140 (`w2.estimated`: passed 2, expected nil). In Lua, `estimated = 0` is truthy, so the Ledger counts it and the weekly assertions fail before the copy comparison is reached.
   - RED probe B (to prove the copy comparison itself): a temporary `row.probe = 0`, which changes no count → `32 successes / 1 failure` at ledger_tab_spec.lua:156, the `assert.same(before[i], row)` line (`*[probe] = 0`).
   - Control: the same probe B with the old `P2.merge({}, live)` copy → `33 successes / 0 failures`. This confirms the old spec could not catch the write.
   - The probe was removed by restoring `UI/Tabs/Ledger.lua` from a copy; the commit touches only the spec.
2. **Boundary spec.** One recipe sale and one unattributed sale sit at exactly `since` (the oldest shown week's start, `rows[8].weekStart`); both are counted in the weekly row 8 and total, in the recipe row and in the unattributed row. Two more sales at `since - 1` are in neither table.

## Tests
- `busted tests/ui/ledger_tab_spec.lua` → `34 successes / 0 failures / 0 errors / 0 pending`.
- `busted` → `1636 successes / 0 failures / 0 errors / 0 pending`.
- `luacheck .` → `0 warnings / 0 errors in 120 files`.
