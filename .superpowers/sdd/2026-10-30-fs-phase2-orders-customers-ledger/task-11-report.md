# Task 11 report: Customers tab

Status: DONE_WITH_CONCERNS (the concerns are in-game checks I could not run, listed below)
Commit: 3a3f9c9 feat: add Customers tab with search, notes, tags, alt links and export (on top of BASE cb34949)

## What was built

`UI/Tabs/Customers.lua`, a `CustomersTab` module with `coreModule = true`. `OnInitialize` registers `"customers"` with `{label="Customers", order=50, phase=2, icon="Interface\\Icons\\INV_Misc_GroupNeedMore", build, refresh}`.

Pure models on `ns.UI.CustomersTab`:
- `ListModel(records)` returns `{nameRealm, orders=n, tipsTotal, lastSeen, tagsText, linkedTo}`. `tagsText` is the sorted tags joined with ", ". There is also an optional `alts` count, set only when a group has alts, so the brief's exact `assert.same` still passes.
- `LinkInput(text)` trims, cuts to 48 characters and goes through `Customers:NormalizeName`. It returns `nil, "empty"` for blank input or nil.
- `Link(alt, text)` = `LinkInput`, then `Customers:Link`. It returns `Link`'s own errors (`self`, `cycle`, `invalid`, `readonly`) unchanged.
- `Groups(text)` applies the orchestrator ruling:
  - It searches with `Customers:Search(text)` and resolves each hit to `Root()`. A hit on an alt therefore shows the main.
  - Each group is a merged record: `members` (main, then alts sorted), `alts`, all members' orders, summed tips, latest lastSeen, and the main's tags. It adds "blocked" when any member is blocked, which is the same rule as `IsBlocked`.
  - Only groups with `#orders > 0` are kept. Newest first, then by name.
- `HistoryRows(name)`: a main's history includes its alts' orders, each marked with `who = alt`. An alt's history is its own. Newest first.
- `Layout(width)` and `CellTexts(row, now)`.

The tab UI is built only from own frames:
- **Top bar:** a search EditBox (40 characters max) that calls `Search` on every text change, a status line, and an Export button.
- **Customer list:** a pooled virtual list in a plain ScrollFrame, with columns Name, Orders, Tips, Last seen, Tags.
  - Name is the flexible first column. The other columns are anchored from the right edge, using the `place_cells` pattern from Orders.
  - Name is red for a blocked customer and gold for a VIP; the selected row is tinted.
  - Tips are compact (`OrdersPanel.CompactMoney`, looked up at call time). Unknown money shows as "no price", never 0g.
  - The row tooltip has the full tips (FormatMoney), the last-seen date, tags, alts and note.
- **Detail pane:** fixed height, at the bottom.
  - The left column (flexible width) has the title ("X (alt of Y)" for an alt), a pooled order history (date `%y-%m-%d`, item name, Q<n>, compact tip) and a "Group:" row of chips from `GetGroup`. Clicking a chip selects that character, which is how you reach an alt to unlink it. A history row's tooltip has the full date and time, the tip, commission and order type. Uncached items are requested once, and the tab refreshes when GET_ITEM_INFO_RECEIVED arrives.
  - The right column (260 px) has the VIP and Blocked check buttons, a multi-line notes box (own ScrollFrame + EditBox, follows the cursor, 500 characters max), a tag field with an "Add tag" button (Enter also works, 24 characters max), removable tag chips (2 lines), and the "Linked to" box with Link and Unlink buttons. Unlink is disabled when the character is not linked.
- **Notes saving:**
  - The note is saved on focus lost, trimmed and UTF-8-safely cut to 500 characters.
  - It is also saved before the selection changes and when the tab hides. It is saved for the character the box shows (`noteOwner`), not whoever is selected at that moment.
  - A refresh never overwrites a notes box that has focus.
- **Export dialog:** own frame `FabricationStationCustomersExport`, BackdropTemplate, DIALOG strata, added to UISpecialFrames.
  - Its multi-line box holds `Customers:Export(names)`. It is focused and fully selected when it opens, and anything typed puts the text back and selects it again.
  - The names are each listed group's main, then its alts. The CSV keeps the `linkedTo` column, so alts are not lost.
- **Writes:** every write goes through `SetNote`, `SetTag`, `Link` and `Unlink`, never to records directly. While `dbIsNewer` is set, the status line says the saved data is read-only.
- **Refresh:**
  - `OnEnable` registers `CUSTOMERS_CHANGED`, wrapped as `Wrap("CustomersTab", …)`. It runs a debounced (0.3 s) whole-list refresh through `MainWindow:RefreshTab("customers")`.
  - `OnDisable` cancels the debounce and hides the dialog.
  - Widget handlers use the SafeCall source `"Tab:customers"`.
  - The tab's own clicks refresh it directly, so it updates at once.

Layout budget (Task 10 lessons): at the minimum 516 px width, Name is 194 px. Below 120 px, Tags is hidden first, then Orders, and this is recomputed in the container's OnSizeChanged hook. The detail pane gives the history ≈236 px at 516, so the Item cell is ≈104 px and its full text is in the tooltip. The list gets about 6 rows at the minimum height of 380 px.

## Files changed
- `UI/Tabs/Customers.lua` (new)
- `tests/ui/customers_tab_spec.lua` (new, 28 specs; the brief's 3 specs are kept unchanged)
- `FabricationStation.toc`: `UI\Tabs\Customers.lua` after `UI\Tabs\Orders.lua`
- `tests/ui/settings_spec.lua`: the registered-tab count goes from 5 to 6. This test counts every tab, and Task 10 made the same change for Orders.

## Tests and TDD evidence
- RED: `busted tests/ui/customers_tab_spec.lua` → every block errors with `failed to load UI/Tabs/Customers.lua: cannot open UI/Tabs/Customers.lua: No such file or directory`.
- GREEN: `busted tests/ui/customers_tab_spec.lua` → `28 successes / 0 failures / 0 errors / 0 pending`.
- Regression check for a review fix (an existing tag must still clear the field): with the fix reverted, the spec fails at `customers_tab_spec.lua:322` (27/1). With the fix restored it passes 28/28.
- Full suite: `busted` → `1587 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` → `0 warnings / 0 errors in 117 files`.
- The frame specs give the frames they create text, check, focus and enabled state through a local `CreateFrame` wrapper in the spec file. The shared stubs keep no such state on frames, and I did not change them. Anchor specs check the header and the rows at 516 px and at 380 px.

## Self-review findings (fixed before commit)
1. Adding a tag the customer already had left the text in the field, because `SetTag` returns false for "no change". The field now clears unless the data is read-only. A regression spec covers this.
2. Calling `Customers:IsBlocked` for every group meant `GetGroup` scanned every record for each group: O(n²) on every search keystroke. Blocked is now worked out from the group's members, which also come from `Root`, so the rule is the same.

## Concerns / notes
- I could not run the in-game check (step 5). The parts least certain in the real client:
  - the `UIPanelScrollFrameTemplate`, `UIPanelCloseButton` and `BackdropTemplate` instances in the export dialog;
  - chip width, which uses `GetFontString():GetStringWidth()` and falls back to an estimate;
  - how the multi-line notes box feels in use.
- Interpretation: the list row aggregates the whole group's orders, tips and lastSeen, as "alts show once, under the main" implies. Tags are the main's, plus "blocked" if any member is blocked. The VIP and Blocked checks in the detail pane are per character, so a main's Blocked box can be unchecked while the list says "blocked" because an alt is blocked. The row tooltip shows the tags in red in that case.
- Interpretation: "Export(visible names)" exports each listed group's main plus its alts, not only the listed mains.
- The brief says `LinkInput` "passes Link errors through". `LinkInput` only normalizes text, so the pass-through is in `Tab.Link(alt, text)`, which returns `Customers:Link`'s errors unchanged.

---

# Fix round 1

Commit: 119d391 fix: fit the Customers history at the minimum width, reach overflowing alts and tags, show blocked-through-alt and read-only state

## Changes, by review item

1. **History width (Important).**
   - Date is now `%m-%d` at 34 px; the full date and time are in the row tooltip. Q is 20 px. Tip is 44 px and uses CompactMoney.
   - The left column ends PAD before the right column (it was 2·PAD).
   - New `Tab.HistoryLayout(width)` returns `{hidden, item, left}`. At 516 px: left column 238, Item = 238 − 2·2 − (34+20+44) − 3·4 = **124 px**.
   - Quality is hidden when Item would drop below 120 (e.g. at 500 px: Item 132 with Q hidden).
   - `apply_layout` re-places the pooled history rows on size changes. New rows use the current layout.
2. **Overflowing chips (Important).**
   - `flow_chips` first checks whether all chips fit. If they don't, it reserves room on the last line for a "+N" chip (`d.groupMore` / `d.chipsMore`). The "+N" chip's `hidden` list holds the values left out, and its tooltip lists them.
   - Clicking "+N" opens an own pick menu: an own BackdropTemplate frame parented to the tab container with UIPanelButtonTemplate buttons, 10 per column, clamped to the screen. It is not UIDropDownMenu.
   - A second click on "+N" closes the menu. It also closes on pick, on every detail refresh, and when the tab hides.
   - Picking a character selects it. Picking a tag removes it and shows `Removed the tag "X" from Name`; removing a tag with its own chip shows the same confirmation.
   - History rows are now Buttons. A row with `who` (an alt's order in the main's history) selects that alt, and its tooltip ends with "Click to show <alt>".
   - Chip tooltips show the full character name (with "(main)" for the main) or the full tag, plus what a click does.
   - The group chip width now comes from `HistoryLayout(width).left − 46`, not the frame's GetWidth, which is 0 before layout.
3. **Blocked roll-up (Minor).**
   - `Groups` now carries `blockedBy = {members whose own record is blocked, in members order}`.
   - `ListModel` adds `blockedVia` (via new `Tab.BlockedVia`) only when the group is blocked through another character and not by the main's own tag. `tagsText` is unchanged, so the brief's spec still holds.
   - The Tags cell reads "blocked (via Name-Realm)" when that fits in about 21 characters (the 130 px cell), else "blocked (alt)". It replaces the exact "blocked" entry, not a substring.
   - The row tooltip has a red "Blocked because X is blocked" line per blocking alt.
   - The detail pane shows a dim, clickable "Group blocked via X" hint next to the Blocked box when this character's own box is unchecked. It has a tooltip and selects X when clicked.
4. **Read-only (Minor).**
   - While `dbIsNewer` is set, every refresh puts a persistent notice in the status line: "Saved data is from a newer version of the addon: read-only, nothing can be changed".
   - VIP, Blocked, the notes box, the tag field, Add tag, the link box, Link and Unlink are disabled. EditBox:Enable/Disable were checked against wow-ui-source's SimpleEditBoxAPIDocumentation.
   - The notes frame doesn't take focus while read-only.
   - A failed note save puts the stored text back in the box.
5. **Root highlight (Minor).** `refresh` computes `view.selectedRoot = Root(selected)`. The row whose nameRealm equals it is highlighted, so selecting an alt highlights its main's row.
6. **Tooltips (Minor).** The detail title has an own mouse area (`d.titleArea`) whose tooltip shows the full title. The link box tooltip starts with "Linked to X" or "Not linked to a main character", then the instructions.
7. **Search (Minor).** The search text is trimmed and cut to 40 characters (UTF-8 safe) before it goes to `Search` and before it is echoed. "|" is escaped in the echo.

Item 6 of the earlier review (Groups keyed by record.nameRealm) is deferred, as instructed. The file's header comment was updated to describe the new behaviour.

## Tests
New or changed specs in `tests/ui/customers_tab_spec.lua` (now 37):
- HistoryLayout at 516, 500 and nil.
- Frame spec of the history row anchors and widths at 516 px: Date LEFT +2 / 34 px, Tip RIGHT −2 / 44 px, Q 20 px, Item anchored between Date and Q with layout width 124 ≥ 120. Also the left column's −PAD anchor, and Q hidden at 500 px with Item re-anchored to Tip.
- 3 alts at 516 px: one chip is shown and "+2" holds Alt2 and Alt3. The "+2" tooltip lists them and a chip tooltip shows its full name. The menu opens, toggles closed, and picking Alt3 selects it; the main's row stays highlighted and Alt3 can be unlinked.
- 8 custom tags: 4 are shown and "+4" holds the rest. Picking tag 8 from the menu removes it with the confirmation status, and "+3" is shown after.
- An alt's order in the main's history selects the alt.
- blockedBy / blockedVia models, the Tags cell texts, the tooltip line, and the detail hint that selects the blocking alt.
- Title and link tooltips.
- The search echo is trimmed, cut to 40 characters and pipe-escaped (search spy now sees "bob").
- Read-only: disabled controls, the notice persists after 60 s, the stored note comes back, the controls re-enable when dbIsNewer clears, and the notice shows from the first refresh.
- The date cell expectation is now `%m-%d`.

RED/GREEN evidence:
- RED: the new spec file run against the committed pre-fix implementation (`git show HEAD:UI/Tabs/Customers.lua > UI/Tabs/Customers.lua; busted tests/ui/customers_tab_spec.lua`) → `24 successes / 10 failures / 3 errors`.
- GREEN: with the fixed implementation restored, `busted tests/ui/customers_tab_spec.lua` → `37 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` → `1596 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` → `0 warnings / 0 errors in 117 files`.

## Remaining concerns
- I have not checked the following in game:
  - the pick menu's look and placement, which uses own frames and UIPanelButtonTemplate;
  - chip widths, which use `GetFontString():GetStringWidth()` and fall back to a 6 px-per-character estimate in tests;
  - whether the "via" text fit threshold (21 characters) matches the real font.
- Clicking elsewhere does not close the menu. It closes on its "+N" chip, on a pick, on any refresh, or when the tab hides.

---

# Fix round 2

Commit: 2ea67ab fix: keep the Customers read-only notice readable, lock tag chips while read-only, and close the pick menu on outside clicks

## Changes, by review item

1. **Read-only notice width (Important).**
   - The notice now reads "Read-only: saved data is from a newer addon version", so "Read-only" leads even when the ~218 px status line cuts the text.
   - The status line has its own mouse area (`view.statusArea`, anchored like the status text) whose tooltip shows the full current status text, like `titleArea`.
2. **Tag chips while read-only (Minor).** `refresh_detail` disables every tag chip and the tag "+N" chip while `dbIsNewer` is set. The group "+N" chip is navigation and stays enabled.
3. **Menu on refresh (Minor).**
   - `refresh_detail` no longer closes the menu at the start. It ends with `sync_menu()`, which closes the menu only when one of these is true:
     - the selection changed since it opened (`menu.selection`);
     - the owner chip is hidden or disabled;
     - the owner chip has nothing left to pick.
   - Otherwise it refills the menu from the owner chip's current hidden list.
   - The opening and the refilling share the new `fill_menu`. The menu still closes when the detail pane shows no selection.
4. **Outside clicks and Escape (Minor).**
   - The menu frame's OnShow registers `GLOBAL_MOUSE_DOWN` on the CustomersTab module. Its OnHide unregisters it.
   - The handler is `ns.FS:Wrap("CustomersTab", …)`. It hides the menu unless the mouse is over the menu frame or its owner chip.
   - The menu is named `FabricationStationCustomersPick` and added to UISpecialFrames, so Escape closes it.
   - `OnDisable`'s `UnregisterAllEvents` also covers it.
5. **"via" name (Minor).** The Tags cell leaves out "-Realm" when the blocking alt's realm equals the main's realm ("blocked (via Al)"). Another realm keeps "Name-Realm", or falls back to "blocked (alt)" when that doesn't fit. The detail hint and the tooltip still give the full name.
6. **Cleanup (Minor).** Chips use only `chip.value`; `chip.tag` and `chip.name` are gone. The blocked hint uses `.value` too.

## Tests
- The spec's stateful frames now run OnShow/OnHide when Show/Hide change the state, as the client does, and support `IsMouseOver` through a `mouseOver` field.
- New or changed specs (42 in total):
  - The notice starts with "Read-only" (colour codes stripped), and the status tooltip shows the full status text.
  - Read-only disables the tag chips and the tag "+N" chip, while the group "+N" chip stays shown and enabled.
  - Pick menu (own `describe`, 3 alts at 516 px):
    - the menu is in UISpecialFrames, `GLOBAL_MOUSE_DOWN` is registered while it is shown, and **nothing is registered after it hides**;
    - a mouse press over the menu or over its chip keeps it open, a press elsewhere closes it and leaves nothing registered;
    - it stays open through a refresh of the same character and refills with a newly linked Alt4;
    - it closes when its chip disappears (the alts are unlinked) and when another character is selected.
  - The Tags cell reads "blocked (via Al)" for the same realm and "blocked (alt)" for a long name on another realm. The frame spec now expects "blocked (via Alt)".
  - Chip assertions use `.value`. Read-only status checks compare case-insensitively.
- RED: the new spec file against the round-1 implementation (`git show HEAD:UI/Tabs/Customers.lua > UI/Tabs/Customers.lua`) → `35 successes / 7 failures / 0 errors`. The menu-closing case passed there only because the old code closed the menu on every refresh.
- GREEN: `busted tests/ui/customers_tab_spec.lua` → `42 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` → `1601 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` → `0 warnings / 0 errors in 117 files`.

## Remaining concerns
I have not tested this in game: the pick menu's look, chip widths, the 21-character fit threshold, and how GLOBAL_MOUSE_DOWN timing interacts with the "+N" click toggle. The toggle relies on the press being over the chip, so the menu stays open until the click's OnClick closes it.
