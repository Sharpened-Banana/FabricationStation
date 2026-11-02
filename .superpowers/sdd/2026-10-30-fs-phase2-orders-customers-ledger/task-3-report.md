# Task 3 report: Orders normalization and reward valuation

Status: DONE_WITH_CONCERNS (only minor concerns, listed below)
Commit: d2031d2 feat: normalize crafting orders and value patron rewards (BASE 2d37766)

## What was built
- `Data/OrderRewards.lua`: pure Lua, `local ADDON_NAME, ns = ...`, then `ns.GameData.Define("OrderRewards", 70575, { items = {}, currencies = {} })`. The build is the same literal as GameData_Manual, never nil. A comment explains the shape and kinds and how to fill the table from an in-game `/dump C_CraftingOrders.GetCrafterOrders()[n].npcOrderRewards`.
- `Modules/Orders.lua` (normal module `Orders`, AceEvent):
  - `Orders.ORDER_TYPES`, `Orders.REAGENT_STATES` as in the brief. `Orders.SETTINGS_DEFAULTS` holds the brief's default table and is exposed for Task 13's settings group.
  - `Orders:Settings()` fills in the missing defaults (deep, without replacing saved values; a value of the wrong type is replaced) in `db.global.settings.orders`, which it creates lazily, and returns that table. While there is no db or `dbIsNewer` is set, it returns a session-only copy instead, so nothing is written.
  - `Orders:Normalize(orderInfo) -> OrderInput|nil`:
    - Enum names are mapped.
    - `recipeID = spellID`.
    - `customer` comes from `Customers:NormalizeName`, looked up at call time. If the Customers module is absent, the raw name is used.
    - `npcCreatureID` is taken from `npcCustomerCreatureID`. A value of 0 or a non-number becomes nil.
    - `expiresAt = Now() + (expirationTime - GetCraftingOrderTime())`. It is nil when either time is unknown.
    - `provided` sums source-1 reagents by `reagentInfo.reagent.itemID`. Entries that have only a currencyID, and damaged entries, are skipped.
    - `rewards` comes from `npcOrderRewards`: `itemLink:match("item:(%d+)")` gives the item, `currencyType` gives `currencyID`, and `count` defaults to 1. A reward whose link has no item ID is kept without an ID, so it still counts as unpriced.
    - All other OrderInput fields are copied as-is.
  - `Orders:ValueRewards(rewards) -> total, valued, unpriced`:
    - Each reward is valued per unit, using the first source that gives a value: override (`item:<id>`/`currency:<id>`), then `OrderRewards` knowledge (`points` × knowledgePointValue, with points defaulting to 1) or moxie, then 1a `MoxieCurrency` values (currencies), then `Prices:Get(id).value` when non-nil (items, kind `"reagent"`), then a currency name matching `moxieNamePattern` (pcall'd; an invalid pattern falls back to a plain find), and finally `"unknown"`.
    - The unit value is multiplied by count and rounded to integer copper.
    - An unknown reward has `value = nil` and sets `unpriced = true`. It is counted in `db.global.ordersUnknownRewards[key] = {count, lastSeen}` (+1 per sighting, created lazily; skipped while read-only or when the reward has no ID).
    - An override keeps the OrderRewards kind if there is one; otherwise its kind is `"override"`.
    - Every lookup is made at call time (GameData tables, Prices, Customers), so tests can redefine or fake them.
- `FabricationStation.toc`: `Data\OrderRewards.lua` after `Data\GameData_Manual.lua`; `Modules\Orders.lua` after `Modules\Customers.lua`. `.luacheckrc` is unchanged.

## Tests
`tests/orders/normalize_spec.lua` contains the brief's 5 tests verbatim plus 9 more:
- order fields and enum mapping, including a 0 npcCreatureID becoming nil
- a non-table order, missing lists and damaged reagent/reward entries
- a nil expirationTime giving `expiresAt = nil`
- Settings fills defaults but keeps saved values (including `false`)
- unknown-reward sighting count and lastSeen, plus a reward with no ID
- an empty or nil reward list giving 0/{}/false
- a missing price is never 0, and an invalid Moxie pattern does not error
- reward table preferred over price, and an override keeping the knowledge kind
- Data file shape and the TOC positions

### TDD evidence
RED: `busted tests/orders/normalize_spec.lua`
```
Error -> tests/orders/normalize_spec.lua @ 4
./tests/helpers/phase2.lua:74: failed to load Data/OrderRewards.lua: cannot open Data/OrderRewards.lua: No such file or directory
```
GREEN: `busted tests/orders` gives `14 successes / 0 failures / 0 errors / 0 pending`. The first GREEN run had 1 error, which was in my own extra TOC test: `read_toc` converts paths to forward slashes, and I fixed the test's keys.

Full suite: `busted` gives `1230 successes / 0 failures / 0 errors / 0 pending` (1216 before this task + 14 new).
Lint: `luacheck .` gives `Total: 0 warnings / 0 errors in 99 files`.

## Files changed
- Data/OrderRewards.lua (new)
- Modules/Orders.lua (new)
- tests/orders/normalize_spec.lua (new)
- FabricationStation.toc

## Self-review findings and concerns
1. **NPC orders keep `customer`.** The brief's test normalizes an `orderType=3` order with the default `customerName = "Bob"` and expects `customer = "Bob-Silvermoon"`, so Normalize does not blank the customer of NPC orders. If NPC orders really carry the NPC's name in `customerName`, Task 4's `blockedCustomer` check could match an NPC name. Task 4/5 should skip customer risks when `orderType == "npc"` (Customers already skips NPC orders on fulfilment).
2. **ordersUnknownRewards counts calls, not orders.** `count` goes up by 1 on every `ValueRewards` call that meets the reward, so rescoring the same order bumps it again. It reads as "times seen". Task 4/5 may want to value each order once per board capture, or treat the count as relative.
3. **Settings replaces wrong-typed values.** `Settings()` replaces a saved value whose type differs from the default (for example a string `moxieValue`), which counts as repairing damaged data. `minScore` has a nil default, so a user's number there is kept untouched.
4. **Unverified in game.** The Midnight knowledge/Moxie reward IDs are unverified; `Data/OrderRewards.lua` stays empty and the dump step is in its comment and the commit message (checklist item). `minQuality` vs `expectedQuality` scale mapping is not done here (Task 4's concern; the plan says map in Normalize if they differ).
5. **No conflicts.** There is no disagreement between the brief, the contract and the 1a/1b code. `GetOrderClaimInfo` is not used in this task.

---

## Fix report — review round 1 (commit 165465e fix: no customer on NPC orders, count unknown rewards once per order)

### Changes
1. **Specs for Settings/write paths** (tests only; existing code already behaved correctly, so these passed on first run):
   - `writes nothing while the saved data is from a newer version`: with `dbIsNewer = true`, Settings() returns a session copy (not the saved table) seeded from the saved `{moxieValue = 30000}` with defaults filled; edits to it persist for the session; ValueRewards still values (override 5 × 2 = 10) and flags unpriced; `settings.orders` stays `{moxieValue = 30000}` and `ordersUnknownRewards` stays nil.
   - `repairs wrong-typed saved settings`: boolean moxieValue, numeric moxieNamePattern, string filters, string claimBlockingRisks.expiringSoon and numeric rewardOverrides are each replaced by their defaults, in the saved table.
   - `Orders before InitDB / works without saved data and writes nothing`: files loaded without booting (`ns.FS.db == nil`). Settings, ValueRewards and Normalize all work, and `ns.FS.db` is still nil afterwards.
2. **Ruling: NPC orders.** `Normalize` sets `customer = nil` when `orderType == "npc"`, with a comment explaining why. The brief's `normalizes a raw order` test now expects nil, with a ruling comment. The new `normalizes the customer name of a player order` test covers public "Bob" → "Bob-Silvermoon" and a personal "Ann-Area52".
3. **Ruling: count each order once.**
   - The signature is now `ValueRewards(rewards, orderID|nil)`. The optional second argument is a backward-compatible addition to the contract; Task 4/5 should pass `input.orderID`.
   - Each `ordersUnknownRewards[key]` entry is now `{count, lastSeen, orders}`. `orders` holds the last 50 orderIDs, so it stays bounded.
   - An orderID already in `orders` only moves `lastSeen`. Without an orderID every call counts, as before.
   - Spec `counts each order once per unknown reward, however often it is valued`: orders 1, 1, 2, 1, 2 give count 2 and lastSeen 2000; a new order 3 gives count 3. The older spec was renamed to `counts every call without an orderID and skips rewards with no id`.
4. **Ruling: numeric strings.** `fill()` turns a numeric string where the default is a number into that number. A non-numeric string is still replaced by the default. Spec `keeps a numeric string setting as a number`: `"30000"` → 30000, `" 1000 "` → 1000, `"lots"` → the default 100000, and a moxie reward of 3 is then valued at 90000.

### TDD evidence
RED: `busted tests/orders`, run after adding the specs and before changing the code:
```
17 successes / 3 failures / 0 errors / 0 pending
Failure -> tests/orders/normalize_spec.lua @ 13    (NPC customer expected nil)
Failure -> tests/orders/normalize_spec.lua @ 98    (count once per order)
Failure -> tests/orders/normalize_spec.lua @ 108   (numeric string setting)
```
GREEN:
- `busted tests/orders`: `20 successes / 0 failures / 0 errors / 0 pending`
- `busted`: `1236 successes / 0 failures / 0 errors / 0 pending`
- `luacheck .`: `Total: 0 warnings / 0 errors in 99 files`

### Remaining notes
- Contract note: `Orders:ValueRewards(rewards, orderID?)` has a new optional second argument. Callers that leave it out count every call, as in d2031d2.
- Concerns 1–3 from the first report are resolved by these rulings. Concern 4 (in-game reward IDs, minQuality scale) still stands.
