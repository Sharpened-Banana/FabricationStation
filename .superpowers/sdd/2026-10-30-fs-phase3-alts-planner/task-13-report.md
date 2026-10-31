# Task 13 report: Characters tab

Status: DONE_WITH_CONCERNS. The in-game steps can't be run here, so they are in the in-game checklist. The plan deviations are listed below.
BASE e9981b6. Commit 53208e6 `feat: add Characters tab with alt grid, details and reagent search`.

## What I built

### `UI/Tabs/Characters.lua`
This file defines the core registrar module `CharactersTab` (`coreModule = true`). It registers tab `"characters"` in `OnInitialize` with `{ label "Characters", icon Achievement_Character_Human_Male, order 70, phase 3, build, refresh }` (preflight row 17).

**Top bar**
- The header shows `CharactersView.Header(rows shown)`. Hovering it shows the header tooltip, which includes the outdated-data marker.
- The search box (`SearchBoxTemplate`) has the placeholder "Find reagent…", is 160 px wide and sits at the top right. The tab's `OnTextChanged` is hooked rather than set, so the template's placeholder and clear button keep working.
- A "Show hidden (N)" check box. Its state is session-local.
- A status line. Its messages lead with the key word ("Hidden: …", "Shown: …", "Search: …"), and hovering it shows the full text.

**Grid**
- The grid is an `ExpandGrid` over `CharactersView.COLUMNS` and `HIDE_ORDER`.
- The row renderer calls `CellTexts` and then `ExpandGrid.SetBadge`, as the Task 12 carry requires.
- A row with `empty` stretches its text across the visible profession columns: the prof1 label's RIGHT is anchored to the last visible profession column.
- The row tooltip is `TooltipLines`.
- The detail is the new `CharactersView.DetailLines`, plus a "Hide character" button. For a hidden row shown under "Show hidden", the button reads "Show character". The button calls `Alts:SetHidden`.
- While `dbIsNewer` is set, the status line says the hiding lasts for this session only. That works because Alts' `SettingsAccessor` keeps a session copy.

**Search**
- `Alts:FindItems` runs 0.3 s after the last keystroke (Task 8 contract). The results replace the grid in a second `ExpandGrid`:
  - Item (flexible), with the `C_Item.GetItemIconByID` icon (feature-tested)
  - Total, with "+" when the row is partial
  - Characters: three "Name: n" entries, then a "+N" badge
  - Warband, which reads "not scanned" when nil
  - The row tooltip lists every holder with their bags, bank, reagent bank and age.
- Clearing the box brings the grid back immediately and cancels any pending search.
- The status line has three forms: "Search: N items", "· +: a bank or the warband bank was never scanned", and an empty-state text for too-short queries and for no match. A `|` in the query is escaped.

**Refresh and lifecycle**
- `FS_ALTS_CHANGED` triggers a 0.5 s Debounce, wrapped under the log-only source `"CharactersTab:Refresh"`, followed by `MainWindow:RefreshTab("characters")`.
- `GET_ITEM_INFO_RECEIVED` is registered only while a search is shown, and unregistered when the search is cleared.
- A 60 s tick keeps the ages and "time to full" values moving, as the Orders tab does.
- While the registrar is off, no timers start.
- `OnDisable` unregisters everything and cancels the refresh, search and tick debounces.
- When Alts is off, the tab shows "Alts is turned off: turn it on in Settings > Modules to see your characters" instead of the grid. The header then reads "Characters".

**Handlers**
UI handlers log under `"Tab:characters"`. A failing handler doesn't stop the registrar (spec).

**Pure helpers**
`ns.UI.CharactersTab.ResultRow(ItemLocationRow, me)` and `SearchStatus(query, rows) -> status, empty|nil`.

### `UI/Tabs/CharactersView.lua`
Added `DetailLines(altRow, now)`. For each listed profession it gives:
- a gold title
- the spec: spent/max, the number unspent with the currency name, and the data age. Without a spec snapshot it reads "no data (open … on <name>)".
- `KnowledgeBreakdown`
- concentration: "full at <date('%a %H:%M')> (in <duration>)", "Full", "not full within 14 days", or "unknown"
- one line per cooldown: the `C_Spell.GetSpellName` name (else "Recipe <id>"), then "ready", "ready in X (Day HH:MM)", or "ready time unknown", plus the charges. It reads "Cooldowns: none" when there are no cooldowns.

After the professions it adds "Older expansions: N (not shown in the grid)", or the empty text when there are no professions.

### `UI/Widgets/ExpandGrid.lua` (Task 12 minors)
- `WrappedHeight` now splits on "\n".
- After the renderer runs, a detail's measured height is used: `text:GetStringHeight()`, rounded up, plus 4, plus `row.detailFooter`. It replaces the estimate at that width and rebuilds the entries once, with a guard against recursion. With no usable measurement, the grid falls back to the estimate. Measurements of removed rows are pruned in `SetRows`.
- Self-review addition: the grid measures only while `text:GetWidth()` is positive. A string whose width isn't laid out yet reports its unwrapped height, which would under-size the detail.

### Other files
- `FabricationStation.toc`: `UI\Tabs\Characters.lua` added after `UI\Tabs\PlannerView.lua` and before Settings (preflight row 3).
- Specs:
  - `settings_spec`: 7 → 8 tabs.
  - `load_all_spec`: `CharactersTab` added (rows 14 and 18).
  - `toc_spec`: a new order check for ExpandGrid < ViewUtil < CharactersView/PlannerView < Characters < Settings (Task 12 minor).
- Contract:
  - `CharactersTab` added to the core-module list.
  - ExpandGrid gains the `WrappedHeight` newline rule, the measured height and `detailFooter`.
  - CharactersView gains `DetailLines`.
  - A new bullet, "[phase 3 Task 13] Characters tab".
- In-game checklist: 5 T13 lines appended. `.superpowers/` is untracked, so these lines are not in the commit.

## Tests

`tests/ui/characters_tab_spec.lua` (26 specs) covers:
- The plan's registration test, verbatim, plus the icon and `coreModule`.
- The header text, the row order (logged-in character first), the class-coloured "•" name, compact gold, "online", the orange stale age, the placeholder and "Show hidden (0)".
- The empty text spanning the profession columns at 516 px (to KP1) and at 716 px (to Spec1), and a reused frame anchoring back to its badge.
- The "+1" badge at 516 px, cleared at 1400 px.
- Row tooltip values.
- The detail text, the detail height (`WrappedHeight` + 28) and the button anchor.
- `DetailLines` for Aria, Bren, Cato and a case with unknown values (no zeros anywhere).
- Hide, Show hidden, Show again, and the status tooltip.
- dbIsNewer: the hide is session-only, `db.global` is not written, and the status says so.
- "Every character is hidden".

Search:
- the 0.3 s debounce over a burst of keystrokes
- results replacing the grid, with cells and tooltip
- the partial "+" and the "not scanned" warband
- three holders plus "+2"
- no match, too short, and the `|` escape
- clearing restores the grid immediately and drops a pending search
- `GET_ITEM_INFO_RECEIVED` refreshes only while searching and is unregistered after clearing

Lifecycle:
- the 0.5 s `FS_ALTS_CHANGED` debounce
- the 60 s tick
- after Disable: everything cancelled, nothing listening, no tick, and typing searches immediately
- the Alts-off state and its recovery
- error isolation under "Tab:characters"

Layout at 516 px:
- the bar anchors
- header 336 px and status 380 px, re-sized at 900 px and back
- grid at the top offset, with a 128 px flex column
- the header tooltip
- the results grid anchored from both edges, with a 172 px flex column
- the outdated marker on the header (`GetBuildInfo` 70700)

Also:
- A full-load spec: the tab ids in order with "characters" at 70, the registrar enabled, no Modules toggle, `/fs tab characters` selects it, and no errors.
- `tests/ui/expand_grid_spec.lua` (+2): measured height (not trusted without a width, then 42+4, the row below shifts, the +28 footer, falling back to the estimate on 0); `WrappedHeight` newline split, including an empty line and per-part wrapping.
- `tests/tooling/toc_spec.lua` (+1): the phase-3 order check.

### TDD evidence

RED, before the implementation:
```
$ busted tests/ui/characters_tab_spec.lua
./tests/helpers/phase2.lua:74: failed to load UI/Tabs/Characters.lua: cannot open UI/Tabs/Characters.lua: No such file or directory
0 successes / 1 failure / 25 errors / 0 pending
$ busted tests/ui/expand_grid_spec.lua tests/tooling/toc_spec.lua
26 successes / 3 failures / 0 errors / 0 pending   (expand_grid_spec @341 measured, @371 newline; toc_spec @44 order)
```

First GREEN run: 22/4. All four failures were slips in my own expectations, not in the code:
- `boot` advances the clock by 1 s, so the expected detail must use `ns.FS:Now()`.
- The status is colour-wrapped, so the comparison needs `plain()`.
- Holders with equal totals are sorted by charKey: Bren comes before Fen.

I fixed the expectations. After the lifecycle tightening, the re-typed query in a spec had to differ, because the same text is a no-op by design.

GREEN:
```
$ busted tests/ui/expand_grid_spec.lua tests/ui/characters_tab_spec.lua
46 successes / 0 failures / 0 errors / 0 pending
$ busted
2168 successes / 0 failures / 0 errors / 0 pending     (was 2139)
$ luacheck .
Total: 0 warnings / 0 errors in 153 files
```

## Deviations (preflight and orchestrator rulings win)

1. The tab is registered by the core registrar in `OnInitialize`, not "at file load" (preflight row 17). The tab listens to `FS_ALTS_CHANGED` itself, and Alts does not call `RefreshTab`.
2. The tab keeps `SearchBoxTemplate`, which preflight row 19 allows; it hooks the template's script rather than replacing it.
3. The "Show hidden" state is session-local to the tab and not saved. The plan doesn't say where to store it, and hiding itself is persisted through Alts.
4. The detail shows nothing for the spec "currency name" beyond the snapshot's `currencyName` ("points" when missing). "Data time" is shown as an age via `FormatAge`, following the rule that ages go through FormatAge.
5. Additions beyond the plan, from the phase-2 precedent:
   - the 60 s tick (Orders)
   - the "Show hidden (N)" count
   - the status line feedback
   - "Every character is hidden"
   - result row tooltips
   - `GET_ITEM_INFO_RECEIVED`, so that names arriving for a search re-run it

## Self-review findings (fixed before commit)

- Unused `GAP` constant (luacheck).
- The tick and the search debounce could start timers after the registrar was disabled, when MainWindow still refreshes on select. They are now guarded by `CharactersTab:IsEnabled()`, and a spec covers it.
- `GET_ITEM_INFO_RECEIVED` was registered for the whole session. It is now registered only while a search is shown, per the binding "register only while needed" rule, and a spec covers it.
- `GetStringHeight` before layout would under-size the detail. Measurement is now gated on a positive text width.
- The contract bullet had been inserted inside the Task 12 sub-list. I moved it.

## Concerns

- No WoW client is available, so the following are on the T13 checklist and unverified:
  - real `GetStringHeight` and `GetWidth` timing for the detail measurement
  - `SearchBoxTemplate`'s `Instructions` field name
  - `|T…|t` icons
  - the hide button fitting inside the 28 px footer
- `date("%a %H:%M")` shows the client's local time. The spec derives its expected value with `os.date`, so it does not depend on the time zone.
- The `ExpandGrid` change is shared with Task 14 (Planner): any detail whose text exists is now measured, and `detailFooter` is available for buttons.

---

# Fix round 1 (commit 6dde7ef, on top of 53208e6)

Status: DONE. All 6 rulings are addressed.

## Changes per ruling

### 1. (Important) Outdated marker cut off at 516 px

- **Compact header gold.** `CharactersView.Header` now shows the gold sum compact in the header text (`ViewUtil.compactMoney`, e.g. "1,234g", "1,234g+"). The tooltip's "Gold:" line keeps the full value.
- **`base` and `note`.** `Header` also returns `base` (the text without the note) and `note`. `text` keeps its old meaning, so other consumers are unaffected.
- **Option chosen: a leading marker in its own region.** I did not use a separate "Outdated:" line. The bar's second line already holds the check box and the status line, so another line would push the grid down for everyone.
  - The marker is a separate orange font string reading "Outdated". It is anchored at one point to the bar's left edge (TOPLEFT 0,-4), with a fixed width of 70 px. That is wider than its 8 characters, about 50 px in GameFontNormal.
  - The header (`Header().base`) follows at 76 px, and its width is reduced by the same amount: 260 px at 516 px.
  - Truncation can therefore only cut the header's tail, never the marker.
  - The marker has its own hover tooltip ("Outdated: data build 70575 (outdated)" plus an explanation), and the header tooltip still explains the note.
  - Without an outdated build, the marker and its hover area are hidden, and the header starts at 0 px with 336 px.
- **Specs at 516 px:**
  - Marker: shown, a single anchor at TOPLEFT of the bar, width 70.
  - Header: at TOPLEFT +76, width 260, and its text no longer contains the note.
  - The marker tooltip.
  - At 900 px: marker 70, header 900−12−168−76.
  - Without the note: header at 0, width 336, compact gold, full gold in the tooltip.

### 2. Tick on hide
The container's `HookScript("OnHide")` cancels the 60 s tick. A spec checks that no refresh happens 120 s after the hide.

### 3. GET_ITEM_INFO_RECEIVED only while needed
- `refresh` now owns the registration: it registers only while a search is shown and Alts is on.
- It is unregistered on OnHide, when Alts is off (the off branch), and when the search is cleared.
- OnEnable no longer registers it.
- A spec covers each step: after a hide nothing fires; the next refresh listens again; after Alts goes off nothing fires.

### 4. Alts-off state
The off branch clears `view.statusText`, so the status hover shows nothing. It sets the label to "Show hidden" with no count and clears the hidden count. The spec hides a character first, then turns Alts off.

### 5. Search wording
- The empty text is now 'No reagent named "x" on your visible characters or in the warband bank'.
- With Show hidden ticked, the empty text adds " (hidden characters are not searched)", and the result status adds " · visible characters only (hidden ones are not searched)".
- The spec checks that a hidden Bren's 3 ore are not listed.

### 6. "Show hidden (N)" label
The label keeps its fixed 90 px width and gets a hover area. The tooltip shows "Show hidden (N)", what hiding means, and that the search, the Planner, the holdings lines and the widget always leave hidden characters out.

### Contract
Updated `Header` (compact gold, `base`/`note`) and the Task 13 bullet: the marker, the listener rules, the OnHide tick, the search wording and the label tooltip.

## Tests

RED: I ran the new and changed specs against the round-0 code.
```
$ busted tests/ui/characters_tab_spec.lua
23 successes / 3 failures / 5 errors / 0 pending   (@307 wording, @319 visible-only, @359 item listener, @425 OnHide tick, @432 off state, @509 marker, @528 header, @538 label tooltip)
```
GREEN:
```
$ busted tests/ui/characters_tab_spec.lua tests/ui/views_spec.lua
62 successes / 0 failures / 0 errors / 0 pending
$ busted
2173 successes / 0 failures / 0 errors / 0 pending   (was 2168)
$ luacheck .
Total: 0 warnings / 0 errors in 153 files
```
The views_spec header expectations were updated for compact gold, and they now assert the full value in the tooltip plus `base`/`note`.

Self-review: luacheck flagged a parameter that shadowed the `showHidden` upvalue. I renamed it to `hiddenShown`.
