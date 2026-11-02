# Task 15 report: Queue tab and restock editor

## Built
- `UI/Tabs/Queue.lua` (module `QueueTab`, coreModule, tab id "queue", order 30, phase 1, label "Queue"). Registered in the toc after Recipes.lua.
- Pure models on `ns.UI.QueueTab`: `BuildRows(entries, costs, missing, readyAt, now)`, `CellTexts`, `StatusText(result, professionName, charName, now?)`, `ShoppingText(ok, info)`, `FormatDuration`, `ParseRestock(itemText, targetText) -> itemID, target | nil, nil, problem`, `BuildRestockRows`.
- UI: top bar (Shopping List, Clear, Craft Next) + one status line; column headers; pooled queue list (36 px two-line rows: line 1 recipe / character / [-] qty [+] / quality / conc on-off / cost / X; line 2 "Missing: 2x item:1001" and "ready in 2h 5m"); restock panel at the bottom (item EditBox, numeric target EditBox, Set, pooled list of targets with Remove). Cycle buttons are not needed here. Computed restock entries show "[restock]" and have no -/+/X.
- Status texts: every CraftNext status (crafted, open, missing, cooldown, busy, empty, unknown/nil) and every ExportShoppingList result (updated N items, N skipped try again, noAuctionator, empty, auctionatorError, other). Status colour is set with SetTextColor, so GetText() is plain text.
- Refresh: `FS_QUEUE_CHANGED`, 0.5 s debounce, only through MainWindow:RefreshTab; own edits (qty, remove, clear, restock) refresh at once. A "Crafting X..." message ends when the queue changes. Handler sources are non-module ("QueueTab:..."); MainWindow supplies "Tab:queue" for build/refresh errors.
- Craft Next: reference only inside the button's OnClick handler (structural test in tests/queue/craft_spec.lua passes; the button field is `craftButton` so no other line contains "CraftNext").
- Read-only: with `ns.FS.dbIsNewer`, qty -/+, X, Clear, Craft Next and restock Set/Remove show "Saved data is from a newer version of FabricationStation; the queue is read-only." and change nothing. Shopping List still works (it writes no saved data).
- Item-link insert: hooks `ChatFrameUtil.InsertLink` (or `ChatEdit_InsertLink`) once via hooksecurefunc; fills the item box when it has focus.

## Tests
`tests/ui/queue_tab_spec.lua` (48 specs; brief's two verbatim) covering models, registration, pooling/clamp/wheel, qty/remove/clear, shopping list, every Craft Next status through the real Queue, restock editor, link hook, refresh/disable/failure isolation.
Also updated `tests/ui/settings_spec.lua` (tab count 3 -> 4; it counted tabs).

- RED: `busted tests/ui/queue_tab_spec.lua` -> `lastFile not found in FabricationStation.toc: UI/Tabs/Queue.lua` (every spec erroring, module missing).
- GREEN: `busted tests/ui/queue_tab_spec.lua` -> 48 successes after fixing one spec of my own (duplicate Add).
- Full: `busted` -> 931 successes / 0 failures / 0 errors. `luacheck .` -> 0 warnings / 0 errors in 82 files.

## Files
UI/Tabs/Queue.lua (new), tests/ui/queue_tab_spec.lua (new), FabricationStation.toc, tests/ui/settings_spec.lua.

## Concerns / notes
- Brief text "N items" kept verbatim, so "1 items" appears for a single item.
- `StatusText` has no recipe parameter in the brief; the tab passes `recipeName` as a field of the result copy. An optional 4th arg `now` was added for the cooldown wait.
- Clear is one click (no confirmation), per the brief. Craft Next is blocked while read-only (it would craft without being able to count the craft off).
- Layout adds a second line per row because MainWindow's minimum content width is about 550 px.
- Link-insert hook and `InputBoxTemplate`/`SetNumeric` are untested in game; ChatFrameUtil.InsertLink vs ChatEdit_InsertLink naming in 12.x is unverified here.
- In-game steps from the brief (Auctionator list, Craft Next with the window open/closed) are not verifiable here.
