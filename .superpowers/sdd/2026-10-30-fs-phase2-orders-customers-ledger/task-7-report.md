# Task 7 report: Ledger capture (craft cost basis, order commissions, AH sale mail)

Status: DONE_WITH_CONCERNS
BASE 4b0db11 -> 101f947 `feat: capture craft cost basis, order commissions and AH sales from mail`

## What was built (Modules/Ledger.lua, new "Capture" section)

- `Ledger.ItemNameFromLink(link)`: text inside `|h[...]|h` (fallback `[...]`), `|A...|a` atlas, `|cXXXXXXXX`/`|cn..:`/`|r` colour markup removed, trimmed. Nil for no link.
- `Ledger:ResolveItemName(name) -> itemID|nil, ambiguous` from `ledger.nameIndex`.
- `Ledger:CostOfCraft(recipeID, craftingReagents, provided, returned) -> cost, incomplete, estimated`, per the brief's rules:
  - entries matched to schematic slots by `dataSlotIndex`; currency entries cost 0; currency-only slots skipped;
  - required slot with no entry: fixed (`dataSlotType ~= ModifiedReagent`) = `reagents[1] x quantity` exact; ModifiedReagent = same but `estimated`; optional/finishing slots with no entry add nothing;
  - provided items are free once (`max(0, used - provided)`, tracked as a decreasing pool so one provided stack is not counted twice);
  - returned reagents subtracted at price; any unpriced item -> `incomplete`, sum of priced only; no schematic -> `incomplete`;
  - result rounded to whole copper (half up); nil when not finite (checked before clamping at 0, because `math.max(0, NaN)` is 0).
- `Ledger:OnCraftRecipe(...)` (CraftRecipe post-hook): pending context `{recipeID, craftingReagents (copy), orderID, provided, castsLeft}`; `provided` from `Orders:GetClaimedOrder()` when its orderID matches (pcall'd, so a failing Orders cannot turn the Ledger off).
- `Ledger:OnCraftResult(event, data)`: multicraft rule first (same non-zero `operationID` as the last recorded craft -> add quantity to that entry and to `costBasis.totalQty` if it fed the basis, no cost, no cast used); else uses the context, decrements `castsLeft`, clears at 0. Craft entry as specified (+ `estimated` when estimated). Non-order, complete crafts feed `costBasis` and `nameIndex` (ambiguous once a second itemID is seen; itemID = most recently crafted). `costBasis`/`nameIndex` are created with the first craft entry.
- `Ledger:OnOrderFulfilled(event, fulfilled)`: commission entry as specified; `cost` = sum of -amount of craft entries with `ref == orderID`, nil when none; an incomplete/estimated craft makes the commission incomplete/estimated. Unknown/non-finite commission -> skipped, logged once.
- `Ledger:OnTakeMoney(index)` (TakeInboxMoney + AutoLootMailItem post-hooks): header money 0 -> skip; invoice `"seller"` -> invoice sale; any other invoice type (buyer, seller_temp_invoice) -> ignored; no invoice -> subject fallback built from `AUCTION_SOLD_MAIL_SUBJECT` (literal English if missing). Dedupe signature `itemName|bid or money|count|playerName|floor(daysLeft*1440)` per session. Cost from costBasis (`floor(totalCost/totalQty*quantity+0.5)`), nil when unknown or ambiguous; `recipeID` from the resolved item's costBasis.
- `OnEnable`: Prune (as before), event `TRADE_SKILL_ITEM_CRAFTED_RESULT`, message `ns.Msg.ORDER_FULFILLED`, all `ns.FS:Wrap("Ledger", ...)`. Hooks installed once (`self.hooked`), bodies return early while disabled, the install itself runs in Wrap. `OnDisable` drops the pending craft and last craft.
- Ruling P3 (code comment at top of the section): hooks on `RecraftRecipe`, `RecraftRecipeForOrder(orderID)`, `CraftEnchant`, `CraftSalvage` (only when the client has them) drop the pending craft; `RecraftRecipeForOrder` marks the order untracked; `data.isEnchant` results are ignored; a claimed order with `isRecraft` records no craft; an untracked (recraft) order records no commission.
- `.luacheckrc`: `GetInboxInvoiceInfo`, `GetInboxHeaderInfo`, `TakeInboxMoney`, `AutoLootMailItem`, `AUCTION_SOLD_MAIL_SUBJECT`.

## Tests

`tests/ledger/capture_spec.lua`: the brief's 8 specs verbatim (before_each only extended: `price`/`schematic` as upvalues, `W` captured, `C_TradeSkillUI` recraft/enchant fakes added to the overrides), plus 23 more: CostOfCraft (estimated quality slot, customer-provided quality slot left out of craftingReagents, no double-counted provided, currency + optional slots, passed optional, unpriced -> incomplete, no schematic), multi-cast + event wiring, incomplete craft excluded from basis and propagated to commission, commission with no crafts (cost nil, counted incomplete) via SendMessage, unknown commission skipped, rounding, non-finite cost (inf and NaN) skipped without disabling, read-only save writes nothing, P3 (recraft/enchant after unfinished multi-cast, isEnchant result, recraft order craft + commission), ItemNameFromLink, ambiguous names (sale gets itemID latest, ambiguous, recipeID, cost nil, counted incomplete), unknown name, subject with stack count, ignored temp invoice / zero money / other subject, hooks installed once and ignored while off.

### TDD evidence
- RED: `busted tests/ledger/capture_spec.lua` -> `0 successes / 1 failure / 30 errors` (`attempt to call method 'OnCraftRecipe' (a nil value)` etc.).
- GREEN: `busted tests/ledger/capture_spec.lua` -> `31 successes / 0 failures / 0 errors`.
- NaN fix: with the old `to_copper(math.max(0, cost))` the new NaN assertion failed (`30 successes / 1 failure`, capture_spec.lua:168); with the fix `31 successes`.
- Full: `busted` -> `1448 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` -> `0 warnings / 0 errors in 109 files`.

## Files changed
- Modules/Ledger.lua
- tests/ledger/capture_spec.lua (new)
- .luacheckrc
- tests/queue/craft_spec.lua (see deviation 1)

## Deviations / brief vs code
1. **1b structural test changed.** `tests/queue/craft_spec.lua` "calls CraftRecipe only inside Queue:CraftNext" matched any substring `CraftRecipe` in code, so the brief-mandated `Ledger:OnCraftRecipe` name and the mandated `hooksecurefunc(C_TradeSkillUI, "CraftRecipe", ...)` both failed it. The test now matches `CraftRecipe` as an exact token and allows exactly one line in Modules/Ledger.lua of the form `hooksecurefunc(C_TradeSkillUI, "CraftRecipe", ...)` with no other CraftRecipe token on it. Checked it still fails for a real call added to Ledger.lua and for a hook line that calls CraftRecipe inside its body.
2. **Customer-provided quality slots** (verified in wow-ui-source live, `ProfessionsCrafterOrderViewMixin:CraftOrder`): Blizzard leaves customer-provided ModifiedReagent slots out of `craftingReagents`. Read literally, the brief would charge such a slot as `reagents[1] x quantity` estimated and then subtract `provided[reagents[1]]`, which misses a provided higher-rank item. CostOfCraft first covers a missing slot from provided items of any of the slot's ranks; only the uncovered rest is charged (estimated only if a ModifiedReagent slot still has a paid part).
3. **Subject fallback reads a stack count**: "Auction successful: X (5)" -> itemName "X", quantity 5 (brief: quantity=1, which still holds without a count). Without it the name would never resolve.
4. Extra fields: `estimated = true` on craft/commission entries when estimated; commission `incomplete = true` when one of its crafts was incomplete.
5. Entries the schematic does not know (dataSlotIndex matches no slot) are still charged rather than dropped.
6. A craft cost is clamped at 0 when returned reagents are worth more than the paid ones.

## Self-review findings (fixed)
- NaN cost (inf - inf) became 0 via `math.max` -> now checked before the clamp (test added).
- costBasis/nameIndex creation: brief test indexes `costBasis` after an order craft -> both are created with the first craft entry (still never while the save is read-only).

## Concerns
- In-game checks not run (no client): craft -> craft entry; Open All -> exactly one sale; whether a multicraft proc arrives as a second `TRADE_SKILL_ITEM_CRAFTED_RESULT` with the same `operationID`; whether the invoice and header money are still readable inside the TakeInboxMoney post-hook; real sold-mail subject format for stacks. Noted in the commit message.
- P3 scope choice: a recraft order's commission is skipped entirely (real gold not in weekly totals), to keep "not tracked" consistent and keep recraft tips out of Benchmark. Recrafts are detected only through the `RecraftRecipeForOrder` hook (or `isRecraft` on the claimed order / a future `fulfilled.isRecraft`); FulfilledOrder from Orders has no `isRecraft` today. If the user prefers the income recorded (cost nil, incomplete), it is a one-line change.
- A pending context from an interrupted multi-cast stays until the next CraftRecipe/recraft/enchant/salvage; a later result from an unhooked source could be charged to it (no age limit).
- `operationID == 0` is treated as "no ID" (the API default), so such results never merge as multicraft extras.

---

## Fix round 1 (commit 21abf99 `fix: record recraft commissions, clear interrupted crafts, flag partial order costs`)

Status: DONE_WITH_CONCERNS

### Changes
1. **Recraft commissions (ruling).**
   - Modules/Orders.lua `OnFulfillClicked`: FulfilledOrder now has `isRecraft = input.isRecraft == true or nil`.
   - `Ledger:OnOrderFulfilled` records a recraft order's commission as `{type="commission", ..., recraft=true, cost=nil}`. A recraft is detected from `fulfilled.isRecraft`, with the session-only `untrackedOrders` (RecraftRecipeForOrder hook, or a claimed order with isRecraft) as the fallback. The order's craft entries are not summed for a recraft.
   - `Ledger:Benchmark` skips `recraft` entries.
   - Recraft crafts, enchants and salvage are still not tracked.
   - The contract's "Phase 2+ shapes" has a new FulfilledOrder line with `isRecraft|nil`. I also added `isRecraft|nil` to the plan's FulfilledOrder shape (line 71) to keep the two the same.
2. **tests/queue/craft_spec.lua.**
   - The matcher is now a local `craft_recipe_refs(line)`.
   - New unit spec: these forms are flagged: `C_TradeSkillUI.CraftRecipe(`, `local craft = C_TradeSkillUI.CraftRecipe`, `["CraftRecipe"]`, `['CraftRecipe']` and `:CraftRecipe()`. `OnCraftRecipe`, `RecraftRecipe` and `RecraftRecipeForOrder` are not.
   - New spec: Modules/Ledger.lua has exactly one allowed post-hook line, `hook(C_TradeSkillUI, "CraftRecipe", function(...) self:OnCraftRecipe(...) end)`. It also has exactly one hooksecurefunc-only helper line and no `tbl[name](` call.
   - The main click-only test allows only that exact line.
3. **Interrupted casts.**
   - `Ledger:OnSpellcastInterrupted` is registered on `UNIT_SPELLCAST_INTERRUPTED`. It clears `pendingCraft` for unit `"player"` when the spellID is nil or equals the pending recipeID. This is the same rule as QueueCraft.
   - I did NOT use `UPDATE_TRADESKILL_CAST_STOPPED`. In Blizzard's source, `ProfessionsCraftingPageMixin` calls `Cleanup()` on it, so it also fires when a batch ends normally. Its order against the last `TRADE_SKILL_ITEM_CRAFTED_RESULT` (which comes from the server) is not verified. If it arrives first, clearing would lose the final cast's entry. A normal batch already clears itself at `castsLeft == 0`.
   - `UNIT_SPELLCAST_FAILED` was left out too. A "busy" failure of a second click would drop the context for the craft still in progress.
4. **Partial order costs.** When an order craft's cost is not finite, `skippedOrderCrafts[orderID]` is set (session). The commission is then `incomplete = true`, even when a partial cost sum exists. Incomplete crafts already made it incomplete.
5. **Hook guard.** CraftRecipe now goes through the same type-guarded `hook` helper as the other hooks.

### Tests
- New specs:
  - capture_spec: recraft commission recorded with `recraft`/no cost and counted incomplete (hook and claimed-order paths); `isRecraft` taken from the FulfilledOrder over existing craft entries; Benchmark skips recraft commissions; partial order cost flagged incomplete (and another order is not affected); interrupted cast clears the pending craft (other unit and other spell ignored).
  - board_spec: FulfilledOrder carries `isRecraft`.
  - craft_spec: the matcher unit spec and the one-allowed-line spec.
- RED (fix code stashed, new tests kept): `busted tests/queue/craft_spec.lua tests/ledger/capture_spec.lua tests/orders/board_spec.lua` gave `132 successes / 6 failures / 1 error`. The failing specs were the two craft_spec structure tests, partial-cost, interrupt, recraft commission, FulfilledOrder isRecraft, and isRecraft-from-fulfilled.
- The Benchmark spec passed under the old code, because recraft commissions were skipped then. With the `not entry.recraft` guard removed, it fails (`34 successes / 1 failure`).
- GREEN: `busted` gave `1455 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 109 files`.

### Concerns
- I used UNIT_SPELLCAST_INTERRUPTED instead of UPDATE_TRADESKILL_CAST_STOPPED, for the ordering reason in item 3. This needs an in-game check if the orchestrator wants CAST_STOPPED as well.
- `skippedOrderCrafts` and `untrackedOrders` are session-only. After a /reload between crafting and fulfilment, a skipped craft is no longer known. The recraft case is covered by `isRecraft` on the FulfilledOrder.
