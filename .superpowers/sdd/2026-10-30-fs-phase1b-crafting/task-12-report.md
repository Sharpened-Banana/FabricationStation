# Task 12 report: Queue shopping list, Craft Next, cooldowns (+ Task 11 review fixes)

Status: DONE_WITH_CONCERNS (concerns at the end; none block)

## Commits
- `9441668` fix: read the queue without repairing a newer save and look up stored entries directly
- `3b1dd9a` feat: add Auctionator shopping list, click-only Craft Next and cooldown checks

## 1. Task 11 review fixes (`fix:` commit, Modules/Queue.lua, tests/queue/queue_spec.lua)
- **Read-only view.** New `view()` returns `{ entries, restock }` from `db.global.queue` without reassigning or repairing anything; missing or malformed parts read as `{}`. GetEntries, GetRestockTargets, GetMissingReagents, GetEntryMissing and GetEntryCost all read through it. `store()` (the repairing accessor) now returns nil unless `writable()`. Remove, SetQuantity, Clear and SetRestock used to call `store()` (which repaired) before checking `writable()`; that is fixed.
- Reads also skip stored entries that are not tables or lack numeric `recipeID`/`quantity`, and restock targets that are not numbers (a newer save can hold anything).
- **find_entry.** It looks up stored entries directly. Only an id starting with `"restock:"` computes a restock entry, and then only that one (`restock:<itemID>`).
- New tests:
  - `blocks Remove, SetQuantity and Clear on existing entries while the saved data is newer`: entries unchanged, no FS_QUEUE_CHANGED.
  - `reads a damaged newer save without repairing it`: `queue = { entries = "future format", restock = 5, extra }` is the same table with the same content after every read API; `queue = nil` stays nil; `{ restock = {...} }` does not gain `entries`.
  - `lets two entries of one character share that character's stock`: two Main entries need 4×1001 and 2×2002 against 3 and 2 held, so 1 is missing and stock is not counted twice.
  - `finds a stored entry without evaluating the restock targets`: exactly 1 Evaluate call for GetEntryCost(id) with a restock target set.
  - `still finds restock entries by their id`.

RED (before the fix): `busted tests/queue/queue_spec.lua` gave `38 successes / 2 failures`. The damaged save was repaired to `entries = {}`, `restock = {}`, and the lookup made 3 Evaluate calls instead of 1. The dbIsNewer-blocks and shared-stock tests passed before the change; they add coverage, as the review asked.
GREEN: `40 successes / 0 failures`.

## 2. Task 12 (Modules/QueueCraft.lua)
- New AceModule `"QueueCraft"` (`coreModule = true`). It adds `Queue:ExportShoppingList`, `Queue:CraftNext` and `Queue:GetCooldownReadyAt` to the Queue module, following the contract's "Queue (+ QueueCraft)". TOC: `Modules\QueueCraft.lua` goes right after `Modules\Queue.lua`.
- **ExportShoppingList:**
  - Gets the API only through `Prices:AuctionatorAPI()`. If the API is missing, or lacks `ConvertToSearchString`/`CreateShoppingList`, it returns `false, "noAuctionator"`.
  - Items and quantities come from `GetMissingReagents(nil)`, sorted by itemID. Nothing missing returns `false, "empty"`.
  - Each term is `{ searchString = name, isExact = true, quantity = n, tier = i }`. `tier` is the item's index in its schematic slot's `reagents`, set only for slots with 2 or more reagents.
  - Each term goes through `ConvertToSearchString(CALLER_ID, term)`, then `CreateShoppingList("FabricationStation", "FabricationStation", searchStrings)`.
  - Every API call is pcall'd. A failure is logged as source `"Queue:ShoppingList"` and returns `false, "auctionatorError"`.
  - An uncached name is skipped and `C_Item.RequestLoadItemDataByID` is called. If every name is uncached, no list is created and it returns `true, { added = 0, skipped = n }`, so no empty search string is ever sent.
- **GetCooldownReadyAt(entry):** reads `Scanner:GetProfession(entry.charKey, schematic.skillLineID).cooldowns[recipeID]`. It returns nil when there is no schematic, no record, `readyAt <= Now()`, or `charges > 0`.
- **CraftNext:**
  - Walks `GetEntries()` and skips entries still on cooldown.
  - The first entry that is on the current character, has its profession open (`Scanner:IsProfessionOpen(GetProfessionInfoByRecipeID(id).professionID)`, falling back to `schematic.skillLineID`), and misses nothing for one craft is crafted with `C_TradeSkillUI.CraftRecipe(recipeID, 1, Scanner:ToCraftingReagentInfo(recipeID, allocation), nil, orderID, useConcentration and true or false)`.
  - "Misses nothing" counts bags + bank + reagentBank, plus the warband when `queueUseWarband` is on. Reagents the order provides are not needed.
  - Otherwise it reports the first blocker in queue order: `open` (another character or the profession not open) or `missing` (with the `missing` table). If every entry is waiting, it returns `cooldown` with the earliest `readyAt`. With no entries it returns `empty`.
  - Every result carries `entryID`, `charKey` and `skillLineID`. It never writes the db.
- **Craft results:**
  - A crafted real entry is added to a session-only pending FIFO (restock entries never are).
  - On `TRADE_SKILL_ITEM_CRAFTED_RESULT` (handler `ns.FS:Wrap("QueueCraft:CraftResult", ...)`, log-only), the oldest pending craft that makes that item is consumed, and its entry drops by 1 through `Queue:SetQuantity`. That call removes the entry at 0 and writes nothing when dbIsNewer.
  - Each `operationID` is counted once, so multicraft extras are ignored. Up to 100 IDs are remembered, then the memory is reset.
  - OnDisable unregisters the event and clears the pending list.
- **Click-only rule:** a structural spec in tests/queue/craft_spec.lua (`click-only crafting`) scans Modules/ and UI/ with comments stripped. It checks that:
  - `CraftRecipe` appears exactly once, in Modules/QueueCraft.lua, inside `function Queue:CraftNext(`.
  - Every `CraftNext(` call's innermost enclosing `function` line contains `OnClick`.

  I checked it by temporarily adding a bad UI file: it failed on both rules and accepted a `SetScript("OnClick", function() ... CraftNext() end)` call. The brief's grep (`grep -rn "CraftNext(" Modules UI | grep -v "function Queue:CraftNext"`) prints nothing; I reworded the module comments so it does.
- **tests/helpers/crafting_world.lua** gained:
  - `world.names`, `loadRequests`, `crafts` (`{ n = select("#", ...), ... }`), `openProfession`, `haveAll`, `cooldown(charKey, recipeID, readyAt, charges?)` and `recordAuctionatorTerms()` (wraps the stub v1 `ConvertToSearchString`/`CreateShoppingList`; returns `{ terms, lists = {caller, name, searchStrings} }`).
  - Fakes for `C_Item.GetItemNameByID`, `C_Item.RequestLoadItemDataByID`, `C_TradeSkillUI.CraftRecipe` and `C_TradeSkillUI.GetProfessionInfoByRecipeID` (`{ professionID = schematic.skillLineID }`). Each is installed unless `opts.stubs` supplies it.
  - The header documents them.

## Tests
- `tests/queue/craft_spec.lua`: the brief's 8 tests (verbatim) plus 24 more, 32 in all. The extras cover core module; converted strings and caller ID; multi-character sums sorted by item; no tier for single-reagent slots; empty; all names loading; Auctionator failures in Create/Convert and their logging; a partial API treated as missing; cooldown readiness (no record, passed, charge, other character, no schematic); Blizzard reagent table, orderID and concentration false; the profession check going through GetProfessionInfoByRecipeID; cooldown skip then craft the next entry; first blocker in queue order with the `missing` table; earliest cooldown; provided reagents and the warband on/off; an unevaluable recipe; decrement once per operation, removal at 0, other items ignored, nothing pending; restock not decremented; dbIsNewer leaves the save unchanged on a result; a failing handler is logged as `QueueCraft:CraftResult` and the module stays on; disable stops counting; and the 2 structural tests.
- RED: `busted tests/queue/craft_spec.lua` errored in before_each with `lastFile not found in FabricationStation.toc: Modules/QueueCraft.lua` (module absent).
- GREEN: `busted tests/queue` gave `72 successes / 0 failures / 0 errors`. On the way, one of my own tests was wrong (`fakeEvaluate(id, nil)` restores the real Evaluate) and I changed it to `function() return nil end`.
- Full suite: `busted` gave `795 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 76 files`.

## Files changed
- Modules/Queue.lua (fix commit)
- tests/queue/queue_spec.lua (fix commit)
- Modules/QueueCraft.lua (new)
- tests/queue/craft_spec.lua (new)
- FabricationStation.toc
- tests/helpers/crafting_world.lua

## Self-review
- No db writes on dbIsNewer: CraftNext and ExportShoppingList only read, and the result handler writes only through SetQuantity, which is guarded. Tested.
- The Auctionator global is not referenced outside Prices. QueueCraft uses `prices():AuctionatorAPI()` with caller ID `"FabricationStation"` and list name `"FabricationStation"`.
- Handlers are wrapped with a non-module source, so a failure is logged and never disables the module. Tested.
- `CraftRecipe` itself is not pcall'd. If it throws, no pending craft is recorded, and the click handler's SafeCall (Tasks 15/16) catches the error.

## Concerns / notes
1. **Auctionator API names are unverified** (the repo was unreachable here). I used what the stub layer fakes and the plan's facts table cites (CraftSim Shopping.lua): `ConvertToSearchString(callerID, term)` and `CreateShoppingList(callerID, listName, searchStrings)`, with term fields `searchString/isExact/quantity/tier`. These need checking in game. This is noted in the module header.
2. **Contract additions/interpretations:** the methods live on Queue but are defined in the QueueCraft module file. "All names uncached" returns `true, { added = 0, skipped = n }` with no list created. An entry whose recipe cannot be evaluated is reported as `missing` with an empty `missing` table. CraftNext results also carry `entryID/charKey/skillLineID` for crafted and cooldown results.
3. **A stale pending craft** (the cast was interrupted, so no result event arrived) stays in the session FIFO. A later craft of the same item from Blizzard's UI would then decrement the entry. This is minor; clearing pending on `UNIT_SPELLCAST_INTERRUPTED/FAILED` could be a follow-up.
4. The result handler finds the current quantity through `Queue:GetEntries()`, which also computes restock entries. That runs once per craft result, so it is cheap enough, and it avoids adding an API outside the contract.
5. The "misses nothing for one craft" check counts the warband when `queueUseWarband` is on, to match GetMissingReagents. Whether the game crafts from warband-bank reagents should be confirmed in game.

---

# Fix round 1

Commit: `118c68e` fix: keep Craft Next scanning past blockers, track one pending craft and widen the click-only check

## Changes
1. **Craft Next stopped at the first blocker** (Modules/QueueCraft.lua, `Queue:CraftNext`). The `elseif not blocker` branch is gone. Every entry not on cooldown is now checked: blocked entries only fill `blocker` when it is still empty (`blocker = blocker or blocked`), and the first craftable entry is crafted. The first blocker is returned only when nothing can be crafted.
2. **One pending craft** (ruling):
   - `pending` is now a single record `{ entryID, recipeID, charKey, skillLineID, isRestock, outputs, hasOutputs }`.
   - While it is set, CraftNext returns `{ status = "busy", entryID, charKey, skillLineID }` and crafts nothing.
   - It is cleared by:
     - the matching `TRADE_SKILL_ITEM_CRAFTED_RESULT` (one of its output items; once per `operationID`);
     - the player's `UNIT_SPELLCAST_INTERRUPTED`/`UNIT_SPELLCAST_FAILED`;
     - a 30 s timeout (`ns.FS:Debounce("QueueCraft:pending", 30, Wrap("QueueCraft:PendingTimeout", ...))`, cancelled when the craft is cleared);
     - its entry no longer existing (checked when CraftNext starts, and the completion handler skips a gone entry).
   - Restock crafts are pending too, so a second click answers "busy" for them as well, but they are never decremented.
   - Interrupt and fail clear the pending craft only for unit "player", and only when the event's spellID is the pending recipeID or is nil. I added that refinement: an unrelated spell failing, for example a mount cast, must not drop a running craft. The ruling did not mention spellID.
   - OnDisable clears the pending craft.
3. **Recipes without an output item** (ruling): when `outputItemIDs` is empty, the player's `UNIT_SPELLCAST_SUCCEEDED` with `spellID == recipeID` completes the craft. For recipes with outputs, SUCCEEDED is ignored and the craft result counts.
4. **Structural test** (tests/queue/craft_spec.lua `click-only crafting`):
   - It now scans Core, Data, Math, Modules and UI.
   - `--[[ ]]` and `--[==[ ]==]` block comments are blanked, keeping line numbers. A new unit test covers `strip_comments`.
   - It matches any `CraftNext` reference outside `function Queue:CraftNext(`. The reference passes only when its own line names `OnClick` (`SetScript("OnClick", Wrap(name, Queue.CraftNext))`) or the innermost `function` line above it does (`SetScript("OnClick", function() ... end)`).
   - Mutation checks, using temporary files that I deleted afterwards:
     - caught: `pcall(Queue.CraftNext, Q)` in a Core function; `local h = Wrap("x", Q.CraftNext)` in UI below an OnClick line; `Q:CraftNext()` in a plain function after an OnClick line;
     - accepted: the `OnClick` Wrap and the multi-line OnClick function;
     - ignored: `CraftRecipe`/`CraftNext` inside block comments.
5. **Contract** (docs/superpowers/plans/2026-10-30-fs-interface-contract.md, Queue section): `"busy"` was added to the CraftNext status set, with the pending-craft lifecycle and the scan-past-blockers rule.
6. **Stubs:** none needed. `W.fire` dispatches any event name, so the specs fire `UNIT_SPELLCAST_*` with `(unit, castGUID, spellID)`.

## Covering tests (tests/queue/craft_spec.lua)
New tests:
- `crafts a stocked entry of this character behind another character's entry`: the reviewer's case; status "crafted" with 1 CraftRecipe call.
- `crafts a later entry when an earlier one of this character misses reagents`.
- `pending craft`:
  - `answers busy to a second click while the craft is pending`;
  - `is cleared by an interrupted or failed cast of the player` (also: another unit or another spellID does not clear it, and a result after the interrupt does not decrement);
  - `is forgotten after 30 seconds` (busy at 29 s, crafts at 31 s);
  - `is dropped when its entry is removed, so it cannot take the next entry's result`: the reviewer's case; B goes from 2 to 1;
  - `ignores a succeeded cast of a recipe that makes an item`.
- `recipe without an output item counts the player's succeeded cast of the recipe as the finished craft` (another spellID and another unit are ignored).
- `blanks block and line comments`.

Adjusted tests:
- `decrements once per operation...` now finishes one craft before the next and checks that an already-counted operationID does not take another craft off.
- The warband test fires a result before its second click.

RED: I ran the new tests against the previous module (`git show 3b1dd9a:Modules/QueueCraft.lua`, the version before this fix, then restored it). `busted tests/queue/craft_spec.lua` gave `32 successes / 8 failures`. The 8 failures were exactly the new behaviour tests: behind-alt, later-entry, busy, interrupted/failed, 30 s, removed-entry, succeeded-ignored and no-output.

GREEN:
```
$ busted tests/queue/craft_spec.lua
41 successes / 0 failures / 0 errors / 0 pending
$ busted
804 successes / 0 failures / 0 errors / 0 pending : 5.115314 seconds
$ luacheck .
Total: 0 warnings / 0 errors in 76 files
$ grep -rn "CraftNext(" Modules UI | grep -v "function Queue:CraftNext"
(no output)
```

## Remaining notes
- The 30 s timeout uses a timer only to clear session state; it never calls a protected function, which matches "no loops, no timers" for protected actions.
- The OnClick rule is still a line-based heuristic. A reference inside a nested non-OnClick function that sits within an OnClick handler is judged by the nearest `function` line, so it would be flagged (strict, which is fine). A sibling function after a one-line OnClick handler is judged by its own line.
