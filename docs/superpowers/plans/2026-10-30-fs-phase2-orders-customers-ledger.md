# FabricationStation Phase 2 — Orders, Customers, Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Score and filter crafting orders, add profit, score and risk columns to Blizzard's crafting-orders list, keep customer records and a profit ledger, and alert the player in game when a personal order arrives.

**Architecture:** Three new AceAddon modules (`Customers`, `Orders`, `Ledger`) hold the data and logic. They read the game only through events and post-hooks, and they price orders through `Recipes:Evaluate` and `Prices:Get`. UI is split into small modules: Blizzard-list additions (`OrdersRowAddons`, `OrdersSidePanel`, `OrderViewWarning`), each of which can be switched off and disables itself if it errors; a personal-order toast (`OrderAlert`); three main-window tabs; and two Dashboard widgets. Each UI file exposes pure "model" functions that busted tests can check without frames.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.x), Ace3 (AceAddon, AceEvent, AceDB, AceConfig), busted, luacheck. Everything from phases 1a and 1b listed in the interface contract.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` (§3, §4, §5.1, §5.3, §7, §11, §12). **Binding names:** `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`. Phases 1a (`2026-10-30-fs-phase1a-foundation.md`) and 1b (`2026-10-30-fs-phase1b-crafting.md`) are assumed complete; their **[1a addition]** / 1b additions used here are named under each task's Consumes.

## Global Constraints

- Retail only (Midnight 12.x); Lua 5.1 semantics; every file begins `local ADDON_NAME, ns = ...`; modules via `ns.FS:NewModule("<Name>", "AceEvent-3.0")`.
- Design rule 2: "FabricationStation never replaces, hides, or reparents Blizzard's Professions or Crafting Orders frames. Its panels dock beside them; every Blizzard button keeps working. Disabling the addon leaves default UI untouched."
- Design rule 3: "Crafting, claiming orders, and buying happen only from a button the player clicks. No loops, no timers, no unattended actions." `C_CraftingOrders.ClaimOrder` is `HasRestrictions = true`.
- Design rule 7: "Only own frames and `hooksecurefunc`-style post-hooks on Blizzard code; never write to Blizzard frame fields or call protected functions from insecure code paths outside a click." Allowed: `hooksecurefunc`, `frame:HookScript`, reading Blizzard fields, anchoring **own** frames to Blizzard frames. Not allowed: assigning any field on a Blizzard frame or table, `SetScript` on a Blizzard frame, calling Blizzard mixin methods that change state (`ViewOrder`, `SetCraftingOrderType`, …).
- Design rule 5: only the Prices module talks to Auctionator.
- Design rule 6: missing prices and stale data stay visible. Unknown money is `nil`, never `0`. A `nil` score sorts last and is never "best".
- Money is integer copper; time is `ns.FS:Now()` server seconds; UI formats with 1a's `ns.UI.FormatMoney(copper|nil)`, which already returns `"--"` for `nil` (never format `nil` as `0`). Ages use 1a's `ns.UI.FormatAge(seconds|nil)` (`"<1m"`, `"Nm"`, `"Nh"`, `"Nd"`, `"never"`).
- §12: event/message handlers and hook bodies are registered as `ns.FS:Wrap("<Module>", fn)` (1a), which runs them inside `ns.FS:SafeCall("<Module>", fn, ...)`. On error 1a's `SafeCall` logs to `db.global.diagnostics.errors` (via `LogError`), disables the module if it is enabled, records `ns.FS.failedModules[name]`, sends `FS_MODULE_FAILED` and prints `FabricationStation: <Module> stopped after an error and was turned off. See /fs settings > Diagnostics.` once per session. 1a's `Debounce` does not isolate errors, so always pass it a `Wrap`ped fn. Blizzard-frame additions can each be switched off.
- Module toggles use 1a's mechanism: every phase-2 feature module (`Customers`, `Orders`, `Ledger`, `OrdersRowAddons`, `OrdersSidePanel`, `OrderViewWarning`, `OrderAlert`) is a normal (non-`coreModule`) module, so it is listed automatically in 1a's `"modules"` options group; its stored state is `db.global.settings.modules[<Name>]` (applied at init by `ApplyModuleSettings`), and code that changes it calls `ns.FS:SetModuleEnabled(name, enabled)`. Phase 2 adds no separate enable flags. The small registrar modules `OrdersTab`, `CustomersTab`, `LedgerTab` and `OrdersWidgets` set `coreModule = true`, like 1a's `SettingsTab`.
- Message names come from 1a's `ns.Msg` (`Core/Bus.lua`): `ns.Msg.PRICES_CHANGED`, `RECIPES_CHANGED`, `ORDERS_CHANGED`, `CUSTOMERS_CHANGED`, `LEDGER_CHANGED`, `MODULE_FAILED`. Task 1 adds `ns.Msg.ORDER_FULFILLED = "FS_ORDER_FULFILLED"` and `ns.Msg.PERSONAL_ORDER_ARRIVED = "FS_PERSONAL_ORDER_ARRIVED"` to `Core/Bus.lua`. Tests may assert the literal strings.
- Other modules are looked up at call time with `ns.FS:GetModule(name)`, never cached at file load, so tests can replace them with fakes.
- Saved data is never wiped. 1a's `ns.DBDefaults` already defines `global.customers = {}`, `global.ledger = { entries = {} }`, `global.ordersSnapshot = { orders = {} }` and `global.settings.modules = {}`; phase 2 creates every other key it uses (`ledger.costBasis`, `ledger.nameIndex`, `ordersState`, `ordersUnknownRewards`, `settings.orders/.alerts/.ledger`) lazily on first access, so modules work right after 1a's `InitDB` even before their own `OnEnable` has run. No migration is needed.
- Blizzard_Professions is LoadOnDemand. Phase-2 modules attach to it with 1b's late-attachment pattern: a single `AttachIfReady()` called from `ADDON_LOADED("Blizzard_Professions")` and from `OnEnable` (`if C_AddOns.IsAddOnLoaded("Blizzard_Professions") and ProfessionsFrame then`), guarded by an `attached` flag so hooks are installed exactly once per session (`hooksecurefunc` cannot be undone; while a module is disabled its hook bodies return early). In Orders this is `InstallBoardHook`; in Task 8 each of the three addition modules has its own. Add `C_AddOns` to the Task 1 stub defaults (`IsAddOnLoaded` → false) and to `.luacheckrc` if 1a/1b have not already.
- §7: alerts are "in-game sound + toast" only; §10: "Notifications outside the game" are out of scope.
- §15: mail parsing handles the English locale first.
- Tests: `busted` from repo root; specs at `tests/<area>/<name>_spec.lua`; lint `luacheck .` must stay clean. 1a's `.luacheckrc` `read_globals` already has `C_CraftingOrders`, `C_CurrencyInfo`, `C_TradeSkillUI`, `Enum`, `ProfessionsFrame`, `hooksecurefunc`, `CreateFrame`, `UIParent`, `GameTooltip`, `GetNormalizedRealmName` and `date`; add only globals not already there, in the task that first uses them. Tests use 1a's harness (`install_wow_stubs`, `load_addon`, `load_files`, `read_toc`, the `W` handle) through the thin wrapper in `tests/helpers/phase2.lua` (Task 1).
- Every new `.lua` file is added to `FabricationStation.toc` in the task that creates it, following 1a's load-order convention (1a's TOC test fails on a listed file that does not exist): `Data\OrderRewards.lua` after `Data\GameData_Manual.lua` (before 1b's `Math\Quality.lua`); `Modules\Customers.lua`, `Modules\Orders.lua`, `Modules\Ledger.lua` (in this order) after 1b's `Modules\SelfCheck.lua`; `UI\Tabs\Orders.lua`, `UI\Tabs\Customers.lua`, `UI\Tabs\Ledger.lua` (in this order) after 1b's `UI\Tabs\Queue.lua` and before `UI\Tabs\Settings.lua`; `UI\OrdersPanel.lua`, `UI\OrderAlert.lua`, `UI\OrdersWidgets.lua`, `UI\OrdersOptions.lua` (in this order) after 1b's `UI\Tooltips.lua`. TOC paths use backslashes like 1a's.
- Commits: conventional (`feat:`, `test:`, `fix:`, `chore:`).

## Review Focus

Five inputs or conditions most likely to cause problems for a player that the spec implies but does not state. Each has a test in its owning task.

1. **Orders that arrive with no `customerName`.** The name can arrive later through `CRAFTINGORDERS_UPDATE_CUSTOMER_NAME`, and NPC orders have no player customer. The order must score without a `blockedCustomer` flag and without errors, and the flag must be recalculated when the name arrives. Tests: Task 3 `normalizes a nil customer name`, Task 5 `applies a late customer name and re-flags a blocked customer`.
2. **AH sale mail for an item with no FS craft record, or whose name matches several quality-rank itemIDs.** The sale is still recorded with `itemID` nil (or the most recently crafted ID, marked `ambiguous`) and `cost = nil`. It is counted as `incomplete` and never shown as a zero-cost sale. Test: Task 7 `records a sale of an uncrafted item as incomplete`.
3. **The same mail's money is taken twice.** This can happen when Open All races a manual click, or when a click repeats while the server command is pending. The result must be exactly one ledger entry. Test: Task 7 `ignores a second take of the same mail`.
4. **A Blizzard patch renames a hook target** (`ProfessionsFrame.OrdersPage`, `ShowOrders`, `OrderView.SetOrder`, the ScrollBox), or a hook body errors. Only that addition disables itself, it logs once, Blizzard's list keeps working, and the other additions keep running. Test: Task 8 `disables only the failing addition`.
5. **The order snapshot is viewed later, or on another character.** Expired orders are hidden, "seen X ago" is shown, and rescoring uses the snapshot's character (not the logged-in one). Test: Task 5 `rescoring uses the snapshot character and GetSnapshot drops expired orders`.

**Not verified from source; the implementer checks each in game before relying on it (record the result in the commit message of the owning task):**
- `GetInboxInvoiceInfo(index)` returns data for an unopened mail. Inside a `hooksecurefunc("TakeInboxMoney")` post-hook, the invoice and header money are still readable (Task 7). If not, switch to scanning on `MAIL_INBOX_UPDATE` with the same dedupe signature.
- `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS` fires at login and when an order arrives away from a crafting table (Task 9). If it only fires at the table, also poll `GetPersonalOrdersInfo()` on `PLAYER_ENTERING_WORLD`. That is a read on an event, not a timer.
- `C_CraftingOrders.GetClaimedOrder().outputItemHyperlink` is filled after crafting, and `C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link)` accepts a hyperlink (Task 5).
- Whether `CraftRecipe`'s `craftingReagents` include customer-provided reagents on order crafts (Task 7). 1b's Queue (Task 12) assumes a multicraft proc arrives as an extra `TRADE_SKILL_ITEM_CRAFTED_RESULT` with the same `operationID`; Task 7 follows the same rule, and the implementer confirms it in game.
- `ScrollUtil.AddAcquiredFrameCallback` and `ScrollUtil.AddReleasedFrameCallback` exist on live (Task 8). After an addon-button `ClaimOrder`, Blizzard's `OrdersPage:CheckForClaimedOrder` shows the claimed order on its next `OnShow`.
- `SOUNDKIT.RAID_WARNING` exists (Task 9).
- Item and currency IDs of Midnight knowledge and Moxie rewards for `Data/OrderRewards.lua` (Task 3); wago.tools blocks automated fetching, so get them from an in-game `/dump` of `npcOrderRewards`.
- `CraftingOrderInfo.minQuality` and `RecipeResult.expectedQuality` use the same quality-tier scale (Task 4). If they differ, map them in `Orders:Normalize`.

## API reference (verified 2026-10-30 against `Gethe/wow-ui-source` branch `live`)

- `C_CraftingOrders`: `GetCrafterOrders() -> CraftingOrderInfo[]` (cumulative across pages), `GetClaimedOrder() -> CraftingOrderInfo|nil`, `GetPersonalOrdersInfo() -> { {profession, numPersonalOrders, professionName} }`, `GetOrderClaimInfo(profession) -> {claimsRemaining, secondsToRecharge}`, `ClaimOrder(orderID, profession)` **HasRestrictions**, `FulfillOrder(orderID, crafterNote, profession)`, `GetCraftingOrderTime() -> time`.
- `CraftingOrderInfo` fields: `orderID, itemID, spellID, skillLineAbilityID, orderType, orderState, expirationTime, claimEndTime, minQuality, tipAmount, consortiumCut, isRecraft, isFulfillable, reagentState, customerGuid?, customerName?, crafterName?, npcCustomerCreatureID?, customerNotes, reagents = { {reagentInfo = {reagent = {itemID?, currencyID?}, dataSlotIndex, quantity}, slotIndex, source, isBasicReagent} }, outputItemHyperlink?, npcOrderRewards = { {itemLink?, currencyType?, count} }, npcCraftingOrderSetID, npcTreasureID`.
- Enums: `CraftingOrderType` Public 0, Guild 1, Personal 2, Npc 3; `CraftingOrderReagentsType` All 0, Some 1, None 2; `CraftingOrderReagentSource` Any 0, Customer 1, Crafter 2, None 3; `CraftingOrderResult` Ok 0 (AlreadyClaimed 2, CannotClaim 6).
- Events: `CRAFTINGORDERS_CLAIM_ORDER_RESPONSE(result, orderID)`, `CRAFTINGORDERS_FULFILL_ORDER_RESPONSE(result, orderID)`, `CRAFTINGORDERS_CLAIMED_ORDER_ADDED`, `CRAFTINGORDERS_CLAIMED_ORDER_UPDATED(orderID)`, `CRAFTINGORDERS_UPDATE_CUSTOMER_NAME(customerName, orderID)`, `CRAFTINGORDERS_UPDATE_REWARDS(npcOrderRewards, orderID)`, `CRAFTINGORDERS_UPDATE_ORDER_COUNT(orderType, numOrders)`, `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS` (no payload).
- Blizzard: the commission shown is `tipAmount - consortiumCut`; time remaining is `expirationTime - C_CraftingOrders.GetCraftingOrderTime()`; claim uses `C_TradeSkillUI.GetChildProfessionInfo().profession`.
- Frames (Blizzard_Professions, LoadOnDemand): `ProfessionsFrame.OrdersPage` (mixin `ProfessionsCraftingOrderPageMixin`) has methods `ShowOrders(offset, isSorted)`, `ShowBuckets(offset, isSorted)` and field `orderType`; list at `ProfessionsFrame.OrdersPage.BrowseFrame.OrderList.ScrollBox` with header `...OrderList.HeaderContainer`; row element data is `{option = CraftingOrderInfo|CraftingOrderBucketInfo, browseType, pageFrame}` (flat rows have `option.orderID`); detail view `ProfessionsFrame.OrdersPage.OrderView:SetOrder(order)`.
- Crafting: `C_TradeSkillUI.CraftRecipe(recipeSpellID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration)` where `craftingReagents = { {reagent = {itemID?, currencyID?}, dataSlotIndex, quantity} }` holds only `ModifiedReagent` data slots (1a "Verified facts"; 1a's `Scanner:ToCraftingReagentInfo` builds the same shape and 1b's `Queue:CraftNext` calls `CraftRecipe` with it); event `TRADE_SKILL_ITEM_CRAFTED_RESULT(data)` with `data = {itemID, quantity, operationID, craftingQuality?, hyperlink, multicraft, resourcesReturned = { {reagent = {itemID?, currencyID?}, quantity} }?, concentrationSpent, ...}`.
- Mail (legacy globals, used by Blizzard_MailFrame): `GetInboxInvoiceInfo(index) -> invoiceType ("buyer"|"seller"|"seller_temp_invoice"), itemName, playerName, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count, commerceAuction`; `GetInboxHeaderInfo(index) -> packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount, wasRead, ...`; money is taken through `TakeInboxMoney(index)` (Open All and single clicks) or `AutoLootMailItem(index)`. Do not call `GetInboxText`, because it marks mail as read.

## Contract additions (Phase 2 owns these; later phases may depend on them)

- Bus: `FS_ORDER_FULFILLED (fulfilled: FulfilledOrder)` and `FS_PERSONAL_ORDER_ARRIVED (professionName, count, delta)`, both sent by Orders; constants `ns.Msg.ORDER_FULFILLED` / `ns.Msg.PERSONAL_ORDER_ARRIVED` (added to 1a's `Core/Bus.lua` in Task 1).
- Shapes:
  - `OrderInput = { orderID, orderType, recipeID, itemID, skillLineAbilityID, minQuality, tipAmount, consortiumCut, reagentState = "all"|"some"|"none", customer = nameRealm|nil, npcCreatureID|nil, expiresAt, provided = {[itemID]=qty}, rewards = { {itemID?, currencyID?, count} }, isRecraft, outputItemHyperlink|nil }`
  - `OrderView` = the contract fields plus `itemID, consortiumCut, commission, rewardsValue, usedConcentration, concentrationCost, net, goldPerConcentration, flags = {noPrice, unknownRecipe, unpricedReward, estimated, stalePrice}, charKey, input = OrderInput`. `tip` is the gross `tipAmount`; `rewards = { {itemID?, currencyID?, count, value|nil, kind} }`. `flags.estimated` / `flags.stalePrice` are copied from 1b's `RecipeResult.flags` (estimated = no calibration for that character); `flags.noPrice` is order-specific (see Task 4) and is **not** 1b's `flags.noPrice`.
  - `FulfilledOrder = { orderID, orderType, customer|nil, npcCreatureID|nil, recipeID, itemID, quality|nil, tip, consortiumCut, commission, rewards, rewardsValue, isRecraft|nil, time, charKey }`
  - `CustomerRecord = { nameRealm, firstSeen, lastSeen, orders = { {time, orderID, itemID, recipeID, quality, tip, commission, orderType} }, tipsTotal, notes, tags = {[tag]=true}, linkedTo = nameRealm|nil }`
  - `LedgerEntry = { time, type = "craft"|"sale"|"commission", itemID|nil, amount, charKey, ref|nil, recipeID?, quality?, quantity?, itemName?, cost?, incomplete?, ambiguous?, customer?, orderType?, tip?, rewardsValue?, source? }`. `amount` is negative for `craft`.
- DB keys: `global.customers` (1a default), `global.ledger = {entries (1a default), costBasis = {[itemID]={totalCost,totalQty,recipeID}}, nameIndex = {[itemName]={itemID, ambiguous}}}`, `global.ordersSnapshot = {time, charKey, orders}` (1a default `{orders = {}}`; `orders` is keyed by `orderID` in storage, and `GetSnapshot` returns a list), `global.ordersState = {[charKey] = {personalCounts = {[profession]=n}}}`, `global.ordersUnknownRewards = {[key] = {count, lastSeen}}`, `global.settings.orders / .alerts / .ledger`. Module on/off state lives in 1a's `global.settings.modules[<Name>]`.
- GameData table `"OrderRewards"`, defined in `Data/OrderRewards.lua` with 1a's `ns.GameData.Define("OrderRewards", <build>, tbl)` and read with `ns.GameData.Get("OrderRewards")`: `{ items = {[itemID] = {kind, points?}}, currencies = {[currencyID] = {kind, points?}} }`, where kind is `"knowledge"`, `"moxie"` or `"reagent"`. `<build>` is the same literal build that `Data/GameData_Manual.lua` uses (70575 at 1a time), never nil, because 1a's `GameData.Status` reports `missing` when any table has a nil build.
- Module names: `Customers`, `Orders`, `Ledger`, `OrdersRowAddons`, `OrdersSidePanel`, `OrderViewWarning`, `OrderAlert` (user-toggleable); `OrdersTab`, `CustomersTab`, `LedgerTab`, `OrdersWidgets` (`coreModule`).

---

### Task 1: Phase-2 test helpers and Customers record store

**Files:**
- Create: `tests/helpers/phase2.lua`, `Modules/Customers.lua`
- Modify: `FabricationStation.toc`, `Core/Bus.lua` (1a-owned: add the two phase-2 `ns.Msg` constants), `tests/helpers/wow_stubs.lua` (1a-owned: phase-2 default fakes, below)
- Test: `tests/customers/customers_spec.lua`

**Interfaces:**
- Consumes (1a): `install_wow_stubs(overrides) -> W` (deep-merges `overrides`; `W.now` drives `GetServerTime`; `W.boot()` runs `OnInitialize` then `OnEnable` on the addon and every enabled module; `W.messages`, `W.printed`, `W.fire`, `W.advance`), `load_addon(ns, lastFile) -> ns`, `load_files(ns, paths) -> ns`, `read_toc(path)`; `ns.FS:Now()`, `ns.FS:CharKey()` (`UnitName("player") .. "-" .. GetNormalizedRealmName()`), `ns.FS:Wrap`, `ns.FS.db.global`, `ns.Msg`.
- Produces:
  - `Core/Bus.lua` additions: `ns.Msg.ORDER_FULFILLED = "FS_ORDER_FULFILLED"`, `ns.Msg.PERSONAL_ORDER_ARRIVED = "FS_PERSONAL_ORDER_ARRIVED"`.
  - `tests/helpers/wow_stubs.lua` additions to the default fakes, so 1a's whole-addon load test (`tests/integration/load_all_spec.lua`) keeps booting with phase-2 files in the TOC: `hooksecurefunc([tbl,] name, fn)` (wraps `tbl[name]` or `_G[name]` so `fn` runs after the original with the same arguments, appends `{tbl, name, fn}` to `W.hooks`, and errors like the real one when the target is not a function); `C_CraftingOrders` functions `GetCrafterOrders, GetClaimedOrder, GetPersonalOrdersInfo, GetOrderClaimInfo, ClaimOrder, FulfillOrder, GetCraftingOrderTime`; `C_TradeSkillUI.CraftRecipe`, `C_TradeSkillUI.GetItemCraftedQualityByItemInfo`; `C_DateAndTime.GetSecondsUntilWeeklyReset`; mail globals `GetInboxInvoiceInfo, GetInboxHeaderInfo, TakeInboxMoney, AutoLootMailItem`; `PlaySound`, `SOUNDKIT = {RAID_WARNING = 8959}`; `ScrollUtil.AddAcquiredFrameCallback/AddReleasedFrameCallback`; `C_AddOns.IsAddOnLoaded` (unless 1b's stubs already provide it). All return 1a's "safe empties".
  - `tests/helpers/phase2.lua` returns `P2`, a thin wrapper over 1a's harness (it adds no loader of its own):
    - `P2.boot(stubOverrides) -> ns, W`: sets `_G.FabricationStationDB = nil`; `W = install_wow_stubs(P2.merge(P2.GLOBALS, stubOverrides or {}))`; `W.now = 1000`; `ns = load_addon({}, "Data/GameData_Manual.lua")` (Core, `ns.Msg`, `ns.DBDefaults`, GameData runtime and 1a data files only); `load_files(ns, {"UI/Util.lua"})` (for `ns.UI.FormatMoney/FormatAge`). It does **not** boot, so tests can add fakes first.
    - `P2.fake_module(ns, name, methods) -> module`: `ns.FS:NewModule(name, "AceEvent-3.0")` with `methods` copied on. Used for 1a/1b modules (`Scanner`, `Prices`, `Recipes`, `MainWindow`, `Dashboard`) and for phase-2 modules a test does not load.
    - `P2.load(ns, paths)`: `load_files(ns, paths)`, then on its first call per `P2.boot` runs `W.boot()` (1a: `InitDB`, `ApplyModuleSettings`, every module's `OnInitialize`/`OnEnable`).
    - `P2.raw_order(overrides) -> CraftingOrderInfo`, `P2.merge(a, b) -> table` (deep merge, `b` wins).
  - `P2.GLOBALS` holds only test values that differ from 1a's defaults: the verified `Enum.CraftingOrderType/CraftingOrderReagentsType/CraftingOrderReagentSource/CraftingOrderResult` values above (deep-merged into 1a's `Enum`), `UnitName = function() return "Me" end` and `GetNormalizedRealmName = function() return "Silvermoon" end` (so `ns.FS:CharKey()` is `"Me-Silvermoon"`), and `date = os.date`.
  - `P2.raw_order` defaults: `{orderID=777, itemID=211111, spellID=4444, skillLineAbilityID=55, orderType=2, orderState=2, expirationTime=8600, claimEndTime=0, minQuality=0, tipAmount=500000, consortiumCut=50000, isRecraft=false, isFulfillable=true, reagentState=0, customerName="Bob", customerNotes="", reagents={}, npcOrderRewards={}, npcCraftingOrderSetID=0, npcTreasureID=0}`.
  - `Customers:NormalizeName(name) -> nameRealm|nil`, `Customers:Get(nameRealm) -> CustomerRecord|nil`, `Customers:RecordOrder(nameRealm, row) -> CustomerRecord`, `Customers:OnOrderFulfilled(event, fulfilled)`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Customers store", function()
  local ns, C
  before_each(function()
    ns = P2.boot(); P2.load(ns, {"Modules/Customers.lua"}); C = ns.FS:GetModule("Customers")
  end)
  it("normalizes names to Name-Realm", function()
    assert.equal("Bob-Silvermoon", C:NormalizeName("Bob"))
    assert.equal("Bob-Area52", C:NormalizeName("Bob-Area52"))
    assert.is_nil(C:NormalizeName(nil)); assert.is_nil(C:NormalizeName(""))
  end)
  it("adds the phase-2 bus names", function()
    assert.equal("FS_ORDER_FULFILLED", ns.Msg.ORDER_FULFILLED)
    assert.equal("FS_PERSONAL_ORDER_ARRIVED", ns.Msg.PERSONAL_ORDER_ARRIVED)
    assert.equal("Me-Silvermoon", ns.FS:CharKey()); assert.equal(1000, ns.FS:Now())
  end)
  it("records a fulfilled order once and totals tips", function()
    spy.on(C, "SendMessage")
    local row = {time=1000, orderID=777, itemID=211111, recipeID=4444, quality=3, tip=500000, commission=450000, orderType="personal"}
    C:RecordOrder("Bob-Silvermoon", row); C:RecordOrder("Bob-Silvermoon", row)
    local r = C:Get("Bob-Silvermoon")
    assert.equal(1, #r.orders); assert.equal(500000, r.tipsTotal)
    assert.equal(1000, r.firstSeen); assert.equal(1000, r.lastSeen); assert.equal("", r.notes)
    assert.spy(C.SendMessage).was.called_with(C, "FS_CUSTOMERS_CHANGED", "Bob-Silvermoon")
  end)
  it("captures player orders on FS_ORDER_FULFILLED and skips NPC orders", function()
    local f = {orderID=1, orderType="public", customer="Ann-Silvermoon", recipeID=4444, itemID=211111, quality=2, tip=100000, consortiumCut=10000, commission=90000, rewards={}, rewardsValue=0, time=1000, charKey="Me-Silvermoon"}
    C:OnOrderFulfilled("FS_ORDER_FULFILLED", f)
    C:OnOrderFulfilled("FS_ORDER_FULFILLED", P2.merge(f, {orderID=2, orderType="npc", customer=nil, npcCreatureID=9}))
    assert.equal(1, #C:Get("Ann-Silvermoon").orders)
    assert.is_nil(C:Get(nil))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/customers/customers_spec.lua`
Expected: FAIL (`tests.helpers.phase2` / `Modules/Customers.lua` not found)

- [ ] **Step 3: Implement the helper and the `Customers` module (`Modules/Customers.lua`)**

Add the two `ns.Msg` constants to `Core/Bus.lua` and the default fakes listed under Interfaces to `tests/helpers/wow_stubs.lua`. `Customers` stores records in `ns.FS.db.global.customers` (1a default; still guard with `or {}`). `NormalizeName` appends the realm part of `ns.FS:CharKey()` to a bare name, so it uses 1a's realm normalization and fallback. `RecordOrder` keeps orders unique by `orderID`, sets `firstSeen` the first time and updates `lastSeen` each time. `OnOrderFulfilled` ignores `orderType == "npc"` and a nil `customer`. `OnEnable` registers `ns.Msg.ORDER_FULFILLED` with `ns.FS:Wrap("Customers", ...)`. Changes send `ns.Msg.CUSTOMERS_CHANGED`. Add `Modules\Customers.lua` to the TOC after `Modules\SelfCheck.lua`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/customers/customers_spec.lua && busted && luacheck .`
Expected: PASS (including 1a's `tests/helpers/wow_stubs_spec.lua` and `tests/integration/load_all_spec.lua`), `0 warnings / 0 errors`

- [ ] **Step 5: Commit**

```bash
git add tests/helpers/phase2.lua tests/helpers/wow_stubs.lua Core/Bus.lua tests/customers/customers_spec.lua Modules/Customers.lua FabricationStation.toc
git commit -m "feat: add Customers record store and phase-2 test helpers"
```

### Task 2: Customer tags, notes, alt linking, search, export

**Files:**
- Modify: `Modules/Customers.lua`
- Test: `tests/customers/tags_links_spec.lua`

**Interfaces:**
- Consumes: Task 1 `Customers` store.
- Produces: `Customers:SetNote(nameRealm, text)`, `Customers:SetTag(nameRealm, tag, on)` (tags `"VIP"` and `"blocked"` are canonical; a custom tag is trimmed and cut to 24 characters, and an empty one is ignored), `Customers:Link(alt, main) -> ok, err` (`err = "cycle"|"self"`), `Customers:Unlink(alt)`, `Customers:Root(nameRealm) -> nameRealm`, `Customers:GetGroup(nameRealm) -> {nameRealm,...}` (root first, then alts sorted), `Customers:IsBlocked(nameRealm) -> bool` (true if anyone in the group has `blocked`), `Customers:Search(text) -> {CustomerRecord}` (case-insensitive plain substring over nameRealm, notes and tag names; sorted by `lastSeen` descending with nil as 0, then by nameRealm; empty text returns all), `Customers:Export(nameRealms|nil) -> string`. Every change creates a missing record and sends `FS_CUSTOMERS_CHANGED`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Customers tags/links/search/export", function()
  local ns, C
  before_each(function()
    ns = P2.boot(); P2.load(ns, {"Modules/Customers.lua"}); C = ns.FS:GetModule("Customers")
    C:RecordOrder("Bob-Silvermoon", {time=1000, orderID=1, itemID=1, recipeID=1, quality=3, tip=500000, commission=450000, orderType="personal"})
  end)
  it("blocks a whole linked group", function()
    C:Link("Alt-Silvermoon", "Bob-Silvermoon"); C:SetTag("Bob-Silvermoon", "blocked", true)
    assert.is_true(C:IsBlocked("Alt-Silvermoon")); assert.is_false(C:IsBlocked("Nobody-Silvermoon"))
    assert.same({"Bob-Silvermoon", "Alt-Silvermoon"}, C:GetGroup("Alt-Silvermoon"))
  end)
  it("refuses cycles and self links", function()
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    assert.same({false, "cycle"}, {C:Link("Bob-Silvermoon", "Alt-Silvermoon")})
    assert.same({false, "self"}, {C:Link("Bob-Silvermoon", "Bob-Silvermoon")})
  end)
  it("searches names, notes and tags", function()
    C:SetTag("Bob-Silvermoon", "VIP", true); C:SetNote("Ann-Silvermoon", "slow payer")
    assert.equal("Bob-Silvermoon", C:Search("vip")[1].nameRealm)
    assert.equal("Ann-Silvermoon", C:Search("SLOW")[1].nameRealm)
    assert.equal(2, #C:Search(""))
  end)
  it("exports CSV with quoting", function()
    C:SetTag("Bob-Silvermoon", "VIP", true); C:SetTag("Bob-Silvermoon", "blocked", true)
    C:SetNote("Bob-Silvermoon", 'pays well, "fast"\nalways')
    assert.equal('nameRealm,orders,tipsTotal,lastSeen,tags,linkedTo,notes\n'
      .. 'Bob-Silvermoon,1,500000,1970-01-01,VIP;blocked,,"pays well, ""fast"" always"',
      C:Export({"Bob-Silvermoon"}))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/customers/tags_links_spec.lua`
Expected: FAIL (`attempt to call method 'Link' (a nil value)`)

- [ ] **Step 3: Implement the functions listed under Interfaces in `Modules/Customers.lua`**

`Link` stores `alt.linkedTo = Root(main)`. A link is a cycle when `Root(main) == alt`. Export: dates use `date("!%Y-%m-%d", lastSeen)`, tags are sorted by byte order and joined with `;`, newlines become a space, and a field containing `,`, `"` or a newline is quoted with `"` doubled.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/customers && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Modules/Customers.lua tests/customers/tags_links_spec.lua
git commit -m "feat: add customer tags, notes, alt linking, search and export"
```

### Task 3: Orders normalization and reward valuation

**Files:**
- Create: `Data/OrderRewards.lua`, `Modules/Orders.lua`
- Modify: `FabricationStation.toc` (`Data\OrderRewards.lua` after `Data\GameData_Manual.lua`; `Modules\Orders.lua` after `Modules\Customers.lua`). `.luacheckrc` needs no change (1a already lists `C_CraftingOrders`, `C_CurrencyInfo`, `Enum`; `Data/` is linted as pure `lua51` and `Data/OrderRewards.lua` uses only `ns`).
- Test: `tests/orders/normalize_spec.lua`

**Interfaces:**
- Consumes: `Customers:NormalizeName` (Task 1); 1a `Prices:Get(itemID) -> {value = copper|nil, source, ageDays}` (never `value = 0` for unknown); 1a `ns.GameData.Define/Get`, 1a GameData table `"MoxieCurrency"` (`[skillLineID] = currencyID`); `C_CraftingOrders.GetCraftingOrderTime()`; `C_CurrencyInfo.GetCurrencyInfo(id).name`.
- Produces: GameData table `"OrderRewards"` (shape and build rule under Contract additions; `Data/OrderRewards.lua` is `local ADDON_NAME, ns = ...` then `ns.GameData.Define("OrderRewards", 70575, { items = {}, currencies = {} })` with a comment explaining how to fill it from an in-game `/dump C_CraftingOrders.GetCrafterOrders()[n].npcOrderRewards`), `Orders.ORDER_TYPES = {[0]="public",[1]="guild",[2]="personal",[3]="npc"}`, `Orders.REAGENT_STATES = {[0]="all",[1]="some",[2]="none"}`, `Orders:Settings() -> table` (fills defaults into `db.global.settings.orders`), `Orders:Normalize(orderInfo) -> OrderInput`, `Orders:ValueRewards(rewards) -> total, valued, unpriced`.
- `Orders:Settings()` defaults: `{lowTipMargin = 100000, expiringSoonSeconds = 3600, knowledgePointValue = 500000, moxieValue = 20000, moxieNamePattern = "Moxie", rewardOverrides = {}, claimMinScore = 0, claimBlockingRisks = {noMatsLowTip=true, unreachableQuality=true, noConcentration=true, expiringSoon=true, blockedCustomer=true}, filters = {hideRisks = {}, orderTypes = {public=true, guild=true, personal=true, npc=true}, minScore = nil, hideUnscored = false}}`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders:Normalize / ValueRewards", function()
  local ns, O, prices
  before_each(function()
    ns = P2.boot({ C_CraftingOrders = { GetCraftingOrderTime = function() return 5000 end },
                   C_CurrencyInfo = { GetCurrencyInfo = function(id) return { name = id == 4000 and "Artisan's Moxie" or "Other" } end } })
    prices = { [210000] = 30000 }
    P2.fake_module(ns, "Prices", { Get = function(_, id) return { value = prices[id], source = prices[id] and "auction" } end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua"})
    ns.GameData.Define("OrderRewards", 70575, { items = { [99001] = {kind="knowledge", points=1} }, currencies = { [3256] = {kind="moxie"} } })
    O = ns.FS:GetModule("Orders")
  end)
  it("normalizes a raw order", function()
    local i = O:Normalize(P2.raw_order({ orderType=3, reagentState=2,
      reagents = { {reagentInfo={reagent={itemID=100}, quantity=3, dataSlotIndex=1}, slotIndex=1, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={itemID=101}, quantity=2, dataSlotIndex=2}, slotIndex=2, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={currencyID=3008}, quantity=5, dataSlotIndex=4}, slotIndex=4, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={itemID=200}, quantity=1, dataSlotIndex=3}, slotIndex=3, source=2, isBasicReagent=true} },
      npcOrderRewards = { {itemLink="|cff0070dd|Hitem:12345::::|h[X]|h|r", count=2}, {currencyType=3056, count=10} } }))
    assert.equal("npc", i.orderType); assert.equal("none", i.reagentState); assert.equal(4444, i.recipeID)
    assert.same({[100]=3, [101]=2}, i.provided)
    assert.same({ {itemID=12345, count=2}, {currencyID=3056, count=10} }, i.rewards)
    assert.equal(4600, i.expiresAt)              -- Now 1000 + (8600 - 5000)
    assert.equal("Bob-Silvermoon", i.customer)
  end)
  it("normalizes a nil customer name", function()
    assert.is_nil(O:Normalize(P2.raw_order({ customerName = P2.NIL })).customer)
  end)
  it("values knowledge, moxie, priced items and flags unpriced rewards", function()
    local total, valued, unpriced = O:ValueRewards({ {itemID=99001,count=2}, {currencyID=3256,count=10}, {itemID=210000,count=5}, {itemID=88888,count=1} })
    assert.equal(1350000, total); assert.is_true(unpriced)
    assert.same({"knowledge","moxie","reagent","unknown"}, {valued[1].kind, valued[2].kind, valued[3].kind, valued[4].kind})
    assert.is_nil(valued[4].value)
    assert.equal(1, ns.FS.db.global.ordersUnknownRewards["item:88888"].count)
  end)
  it("uses the Moxie name fallback and per-reward overrides", function()
    O:Settings().rewardOverrides["item:88888"] = 70000
    local total, _, unpriced = O:ValueRewards({ {currencyID=4000,count=3}, {itemID=88888,count=1} })
    assert.equal(130000, total); assert.is_false(unpriced)
  end)
  it("treats 1a's MoxieCurrency ids as Moxie", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 })
    local total, valued = O:ValueRewards({ {currencyID=3300,count=2} })
    assert.equal(40000, total); assert.equal("moxie", valued[1].kind)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/orders/normalize_spec.lua`
Expected: FAIL (`Modules/Orders.lua` not found)

- [ ] **Step 3: Implement `Data/OrderRewards.lua` and `Orders:Settings/Normalize/ValueRewards` in `Modules/Orders.lua`**

`Normalize`:
- `provided` sums customer-source (`1`) reagents. The itemID is `reagentInfo.reagent.itemID` (1a's verified Midnight `CraftingReagentInfo` shape, `{reagent = {itemID?, currencyID?}, dataSlotIndex, quantity}`); entries with only a `currencyID` are skipped.
- `expiresAt = ns.FS:Now() + (expirationTime - C_CraftingOrders.GetCraftingOrderTime())`.
- The reward itemID comes from `itemLink:match("item:(%d+)")`.

`ValueRewards` checks these sources in order, per unit, and uses the first that gives a value:
1. `rewardOverrides["item:<id>"|"currency:<id>"]`
2. `ns.GameData.Get("OrderRewards")`: `knowledge` → `points × knowledgePointValue`; `moxie` → `moxieValue`
3. for currencies, an id that is a value in 1a's `ns.GameData.Get("MoxieCurrency")` (kind `"moxie"`, `moxieValue`)
4. for items, `Prices:Get(itemID).value` when non-nil (kind `"reagent"`)
5. for currencies, a name containing `moxieNamePattern` (kind `"moxie"`)
6. otherwise kind `"unknown"`, `value = nil`, `unpriced = true`, and a count is added to `db.global.ordersUnknownRewards[key]` with `lastSeen = Now()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/orders && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Data/OrderRewards.lua Modules/Orders.lua tests/orders/normalize_spec.lua FabricationStation.toc
git commit -m "feat: normalize crafting orders and value patron rewards"
```

### Task 4: Order scoring, risk flags, filters, best claimable order

**Files:**
- Modify: `Modules/Orders.lua`
- Test: `tests/orders/score_spec.lua`

**Interfaces:**
- Consumes: 1b `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult` with `opts = {targetQuality?, useConcentration?, providedReagents = {[itemID]=qty}?}` (`ownedReagentsFree` left nil so 1a's `settings.costing.ownedReagentsFree` applies). Fields used: `expectedQuality`, `allocation = { {slotIndex, itemID, quantity} }`, `reagentCost` (copper; already excludes `providedReagents`), `concentrationCost` (points spent up front), `expectedConcentrationCost` (points after Ingenuity refunds; the unit of 1b's `goldPerConcentration`), `flags = {noPrice, stalePrice, staleData, unknownRecipe, estimated}`. `ingenuityValue` is concentration points, not copper, and is not used. 1b's `flags.noPrice` is also set when only an *output* price is missing, which does not matter for an order (the customer receives the item), so Orders computes its own `noPrice` below. 1b `Recipes:GetRanked(filter)`; 1a `Scanner:GetSchematic(recipeID).skillLineID`; 1a `Scanner:ProjectConcentration(charKey, skillLineID, atTime) -> value, max` (nil without a snapshot); 1a `Prices:Get`; `Customers:IsBlocked`; Task 3 `Normalize`, `ValueRewards`, `Settings`.
- Produces: `Orders.RISKS = {"noMatsLowTip","unreachableQuality","noConcentration","expiringSoon","blockedCustomer"}` (in this order; a view's `risks` list follows the same order); `Orders.RISK_LABELS = {noMatsLowTip="No mats, low tip", unreachableQuality="Can't reach min quality", noConcentration="Not enough concentration", expiringSoon="Expiring soon", blockedCustomer="Blocked customer"}`; `Orders:BuildContext(charKey) -> ctx = {charKey, now, bestGPC, concentrationFor = fn(recipeID) -> number|nil}`; `Orders:ScoreInput(input, ctx) -> OrderView`; `Orders:Score(orderInfo) -> OrderView` (contract; `= ScoreInput(Normalize(orderInfo), BuildContext(ns.FS:CharKey()))`); `Orders:IsHidden(view, filters) -> bool`; `Orders:Filter(views, filters) -> views` (visible only, sorted by score descending, nil scores last); `Orders:GetBestClaimable(views, claim) -> view|nil, reason` with `claim = {claimsRemaining = n, hasClaimed = bool}` and `reason` one of `"alreadyClaimed"`, `"none"`.
- `bestGPC` = `Recipes:GetRanked({charKey=charKey, usesConcentration=true, sortBy="goldPerConcentration"})[1].goldPerConcentration`, floored at 0, or 0 when there are no results.

Scoring algorithm (the signature does not determine it):

```lua
local commission = input.tipAmount - input.consortiumCut
local rewardsValue, rewards, unpriced = self:ValueRewards(input.rewards)
local target = (input.minQuality or 0) > 1 and input.minQuality or nil
local opts = { targetQuality = target, providedReagents = input.provided }
local r, usedConc = Recipes:Evaluate(input.recipeID, ctx.charKey, opts), false
if target and (r.expectedQuality or 0) < target then
  opts.useConcentration = true
  r, usedConc = Recipes:Evaluate(input.recipeID, ctx.charKey, opts), true
end
local concCost = usedConc and (r.concentrationCost or 0) or 0
local concCharge = usedConc and (r.expectedConcentrationCost or concCost) or 0   -- same unit as bestGPC
local net = commission + rewardsValue - (r.reagentCost or 0)
-- order-specific noPrice: a reagent the crafter pays for has no price (output price is irrelevant)
local noPrice = r.reagentCost == nil
for _, a in ipairs(r.allocation or {}) do
  if a.quantity - (input.provided[a.itemID] or 0) > 0 and Prices:Get(a.itemID).value == nil then noPrice = true end
end
local scorable = not (noPrice or r.flags.unknownRecipe)
local score = scorable and (net - math.floor(concCharge * ctx.bestGPC)) or nil
-- view.flags = {noPrice = noPrice, unknownRecipe = r.flags.unknownRecipe, unpricedReward = unpriced,
--               estimated = r.flags.estimated, stalePrice = r.flags.stalePrice}
-- risks:
--  noMatsLowTip       reagentState == "none" and commission - reagentCost < settings.lowTipMargin
--  unreachableQuality target and (r.expectedQuality or 0) < target   (1b does not define the result for an
--                     unreachable targetQuality; treat a nil expectedQuality as unreached, never error)
--  noConcentration    usedConc and not unreachable and ctx.concentrationFor(recipeID) ~= nil and concCost > that value
--  expiringSoon       input.expiresAt - ctx.now < settings.expiringSoonSeconds
--  blockedCustomer    input.customer and Customers:IsBlocked(input.customer)
-- goldPerConcentration = concCost > 0 and math.floor(net / concCost) or nil
```

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders scoring", function()
  local ns, O, ev
  local function ctx(o) return P2.merge({charKey="Me-Silvermoon", now=1000000, bestGPC=1000, concentrationFor=function() return 40 end}, o) end
  local function input(o) return P2.merge({orderID=777, orderType="personal", recipeID=4444, itemID=211111, minQuality=2,
    tipAmount=500000, consortiumCut=50000, reagentState="all", customer="Bob-Silvermoon", expiresAt=1086400, provided={}, rewards={}}, o) end
  before_each(function()
    ns = P2.boot()
    ev = { plain = {expectedQuality=3, reagentCost=200000, concentrationCost=0, flags={}},
           conc  = {expectedQuality=4, reagentCost=200000, concentrationCost=50, expectedConcentrationCost=50, flags={}} }
    P2.fake_module(ns, "Recipes", { Evaluate = function(_, _, _, o) return o.useConcentration and ev.conc or ev.plain end })
    P2.fake_module(ns, "Customers", { IsBlocked = function(_, n) return n == "Bad-Silvermoon" end, NormalizeName = function(_, n) return n end })
    P2.fake_module(ns, "Prices", { Get = function(_, id) return { value = id == 100 and 1000 or nil } end })
    P2.load(ns, {"Data/OrderRewards.lua", "Modules/Orders.lua"}); O = ns.FS:GetModule("Orders")
  end)
  it("scores commission minus reagent cost", function()
    local v = O:ScoreInput(input(), ctx())
    assert.equal(450000, v.commission); assert.equal(250000, v.net); assert.equal(250000, v.score)
    assert.is_false(v.usedConcentration); assert.same({}, v.risks); assert.equal(500000, v.tip)
  end)
  it("charges concentration at the best gold per concentration", function()
    local v = O:ScoreInput(input({minQuality=4}), ctx())
    assert.is_true(v.usedConcentration); assert.equal(50, v.concentrationCost)
    assert.equal(200000, v.score); assert.equal(5000, v.goldPerConcentration)
    assert.same({"noConcentration"}, v.risks)
  end)
  it("flags unreachable quality instead of concentration", function()
    ev.conc.expectedQuality = 3
    assert.same({"unreachableQuality"}, O:ScoreInput(input({minQuality=4}), ctx()).risks)
  end)
  it("flags no-mats low tip, expiring, blocked", function()
    ev.plain.reagentCost = 100000   -- commission 135000 - 100000 = 35000 < 100000 margin
    local v = O:ScoreInput(input({reagentState="none", tipAmount=150000, consortiumCut=15000, expiresAt=1001800, customer="Bad-Silvermoon"}), ctx())
    assert.same({"noMatsLowTip","expiringSoon","blockedCustomer"}, v.risks)
    assert.same({}, O:ScoreInput(input({reagentState="none", tipAmount=300000, consortiumCut=30000}), ctx()).risks)
  end)
  it("leaves score nil when a paid reagent has no price", function()
    ev.plain.allocation = { {slotIndex=1, itemID=100, quantity=2}, {slotIndex=2, itemID=200, quantity=3} }
    local v = O:ScoreInput(input(), ctx()); assert.is_nil(v.score); assert.is_true(v.flags.noPrice)
    assert.equal(250000, O:ScoreInput(input({provided={[200]=3}}), ctx()).score)   -- the customer provides the unpriced one
  end)
  it("still scores when only 1b's output price is missing, and passes estimated through", function()
    ev.plain.flags = {noPrice=true, estimated=true}
    local v = O:ScoreInput(input(), ctx())
    assert.equal(250000, v.score); assert.is_false(v.flags.noPrice); assert.is_true(v.flags.estimated)
  end)
  it("filters and picks the best claimable order", function()
    local A = {orderID=1, orderType="personal", score=300000, risks={"expiringSoon"}}
    local B = {orderID=2, orderType="public", score=200000, risks={}}
    local C = {orderID=3, orderType="public", score=nil, risks={}}
    local D = {orderID=4, orderType="personal", score=100000, risks={}}
    assert.equal(2, O:GetBestClaimable({A,B,C,D}, {claimsRemaining=2}).orderID)
    assert.equal(4, O:GetBestClaimable({A,B,C,D}, {claimsRemaining=0}).orderID)
    assert.same({nil, "alreadyClaimed"}, {O:GetBestClaimable({B}, {claimsRemaining=2, hasClaimed=true})})
    local f = {hideRisks={expiringSoon=true}, orderTypes={public=true, personal=true}, hideUnscored=true}
    assert.same({2, 4}, (function() local t={} for _,v in ipairs(O:Filter({A,B,C,D}, f)) do t[#t+1]=v.orderID end return t end)())
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/orders/score_spec.lua`
Expected: FAIL (`attempt to call method 'ScoreInput' (a nil value)`)

- [ ] **Step 3: Implement the functions listed under Interfaces in `Modules/Orders.lua`**

`GetBestClaimable` picks the highest `score` among views with `score ~= nil`, `score > claimMinScore`, and no risk in `claimBlockingRisks`. A `public` order also needs `claim.claimsRemaining > 0`. `IsHidden` is true when the view's type is not in `orderTypes`, any risk is in `hideRisks`, `hideUnscored` is set and `score == nil`, or `minScore` is set and the score is below it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/orders && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Modules/Orders.lua tests/orders/score_spec.lua
git commit -m "feat: score crafting orders with risk flags, filters and best-claim selection"
```

### Task 5: Order board capture, snapshot, live updates, Claim Best Order, fulfilment, personal counts

**Files:**
- Modify: `Modules/Orders.lua`, `.luacheckrc` (`C_AddOns`, unless 1b already added it; 1a already lists `ProfessionsFrame`, `hooksecurefunc`, `C_TradeSkillUI`, `C_CraftingOrders`)
- Test: `tests/orders/board_spec.lua`, `tests/orders/claim_click_only_spec.lua`

**Interfaces:**
- Consumes: Task 4 scoring; 1a `ns.FS:Debounce(key, seconds, fn)` (trailing, not error-isolated), `ns.FS:Wrap(moduleName, fn)`, `ns.FS:LogError(source, errText)`, `ns.Msg`; 1a `read_toc` (test only); `C_CraftingOrders.GetCrafterOrders/GetClaimedOrder/GetOrderClaimInfo/ClaimOrder/GetPersonalOrdersInfo`; `C_TradeSkillUI.GetChildProfessionInfo().profession`; `C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link)`.
- Produces:
  - `Orders:OnBoardShown(orderTypeEnum, orders)` replaces that type's views in the live set and in `db.global.ordersSnapshot` (the snapshot stores a trimmed deep copy of each `OrderView`: `result` keeps only `expectedQuality, reagentCost, expectedSale, profit, concentrationCost, goldPerConcentration, flags`, never the shared cached table — test `snapshot_stores_trimmed_copy`), sets `snapshot.time = Now()` and `snapshot.charKey`, and sends `ns.Msg.ORDERS_CHANGED`.
  - `Orders:GetSnapshot() -> {time, charKey, orders}` (contract; leaves out views with `expiresAt < Now()`).
  - `Orders:GetLiveViews() -> {OrderView}` (current board only; empty after the Professions frame closes).
  - `Orders:GetView(orderID) -> OrderView|nil` (live first, then snapshot).
  - `Orders:Rescore()` (snapshot and live views from stored `input`, using `BuildContext(snapshot.charKey)`).
  - `Orders:OnCustomerNameUpdated(event, name, orderID)`, `Orders:OnRewardsUpdated(event, rewards, orderID)`.
  - `Orders:GetClaimedOrder() -> OrderInput|nil`.
  - `Orders:ClaimBest() -> view|nil, reason`: calls `ClaimOrder` at most once. Only `OrdersSidePanel`'s `OnClick` may call it.
  - `Orders:OnFulfillClicked(orderID, note, profession)` (post-hook on `C_CraftingOrders.FulfillOrder`), `Orders:OnFulfillResponse(event, result, orderID)`: sends `ns.Msg.ORDER_FULFILLED` and removes the order from the snapshot.
  - `Orders:UpdatePersonalCounts(infos) -> arrivals` with `{ {profession, professionName, count, delta} }`; sends `ns.Msg.PERSONAL_ORDER_ARRIVED(professionName, count, delta)` for each arrival.
  - `Orders:InstallBoardHook() -> bool`.
- `OnEnable` registers, each handler wrapped with `ns.FS:Wrap("Orders", ...)`:
  - game events: `CRAFTINGORDERS_UPDATE_CUSTOMER_NAME`, `CRAFTINGORDERS_UPDATE_REWARDS`, `CRAFTINGORDERS_FULFILL_ORDER_RESPONSE`, `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS`, and `CRAFTINGORDERS_UPDATE_ORDER_COUNT` (Personal type only; both count events call `UpdatePersonalCounts(C_CraftingOrders.GetPersonalOrdersInfo())`)
  - messages `ns.Msg.PRICES_CHANGED`, `ns.Msg.RECIPES_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED`, each calling `ns.FS:Debounce("orders.rescore", 0.5, ns.FS:Wrap("Orders", function() self:Rescore() end))`
  - `hooksecurefunc(C_CraftingOrders, "FulfillOrder", ...)`, installed once per session (guard `self.hooked`); its body returns early while `not self:IsEnabled()`
  - `InstallBoardHook` through the late-attachment pattern in Global Constraints (`ADDON_LOADED("Blizzard_Professions")` and `OnEnable`, `attached` flag)

  `InstallBoardHook` post-hooks `ProfessionsFrame.OrdersPage` `ShowOrders` and calls `OnBoardShown(page.orderType, C_CraftingOrders.GetCrafterOrders())`. If the target is missing it returns false, calls `ns.FS:LogError("Orders", "hook target missing: ProfessionsFrame.OrdersPage.ShowOrders")` and prints one chat line; the rest of Orders keeps working. It also hooks `ProfessionsFrame` `OnHide` (via `HookScript`) to clear the live views.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders board", function()
  local ns, O, W, claimed, claimCalls
  before_each(function()
    claimed, claimCalls = nil, {}
    ns, W = P2.boot({
      C_CraftingOrders = { GetCraftingOrderTime = function() return 5000 end, GetClaimedOrder = function() return claimed end,
        GetOrderClaimInfo = function() return {claimsRemaining = 3} end, ClaimOrder = function(id, p) claimCalls[#claimCalls+1] = {id, p} end },
      C_TradeSkillUI = { GetChildProfessionInfo = function() return {profession = 7} end,
        GetItemCraftedQualityByItemInfo = function() return 3 end } })
    P2.fake_module(ns, "Recipes", { Evaluate = function() return {expectedQuality=3, reagentCost=200000, flags={}} end, GetRanked = function() return {} end })
    P2.fake_module(ns, "Customers", { IsBlocked = function(_, n) return n == "Bad-Silvermoon" end,
      NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Silvermoon") end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return {skillLineID = 2900} end, ProjectConcentration = function() return 500, 1000 end })
    P2.load(ns, {"Data/OrderRewards.lua", "Modules/Orders.lua"}); O = ns.FS:GetModule("Orders")
  end)
  it("replaces only the shown order type in the snapshot", function()
    O:OnBoardShown(0, { P2.raw_order({orderID=1, orderType=0}), P2.raw_order({orderID=2, orderType=0}) })
    O:OnBoardShown(2, { P2.raw_order({orderID=3}) })
    assert.equal(3, #O:GetSnapshot().orders)
    O:OnBoardShown(0, {})
    assert.equal(1, #O:GetSnapshot().orders); assert.equal(1000, O:GetSnapshot().time)
    assert.equal("Me-Silvermoon", O:GetSnapshot().charKey)
  end)
  it("applies a late customer name and re-flags a blocked customer", function()
    O:OnBoardShown(2, { P2.raw_order({customerName = P2.NIL}) })
    assert.same({}, O:GetView(777).risks)
    O:OnCustomerNameUpdated("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", "Bad", 777)
    assert.equal("Bad-Silvermoon", O:GetView(777).customer); assert.same({"blockedCustomer"}, O:GetView(777).risks)
  end)
  it("rescoring uses the snapshot character and GetSnapshot drops expired orders", function()
    O:OnBoardShown(2, { P2.raw_order({orderID=1}), P2.raw_order({orderID=2, expirationTime=4000}) })  -- expiresAt 0
    ns.FS.CharKey = function() return "Alt-Silvermoon" end; local s = spy.on(O, "BuildContext")
    O:Rescore()
    assert.spy(s).was.called_with(O, "Me-Silvermoon")
    assert.equal(1, #O:GetSnapshot().orders)
  end)
  it("debounces rescoring on bus messages", function()
    local s = spy.on(O, "Rescore")
    ns.FS:SendMessage("FS_PRICES_CHANGED", 2); ns.FS:SendMessage("FS_CUSTOMERS_CHANGED", "Bob-Silvermoon")
    W.advance(0.4); assert.spy(s).was_not.called(); W.advance(0.2); assert.spy(s).was.called(1)
  end)
  it("claims the best order once and refuses while one is claimed", function()
    O:OnBoardShown(2, { P2.raw_order({orderID=10, tipAmount=900000}), P2.raw_order({orderID=11}) })
    assert.equal(10, O:ClaimBest().orderID); assert.same({{10, 7}}, claimCalls)
    claimed = P2.raw_order({orderID=10})
    assert.same({nil, "alreadyClaimed"}, {O:ClaimBest()}); assert.equal(1, #claimCalls)
  end)
  it("sends FS_ORDER_FULFILLED on a successful fulfil response", function()
    claimed = P2.raw_order({outputItemHyperlink = "|Hitem:211111::|h[Potion]|h"})
    spy.on(O, "SendMessage")
    O:OnFulfillClicked(777, "", 7)
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 10, 777)   -- CannotFulfill: nothing sent
    assert.spy(O.SendMessage).was_not.called()
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
    assert.spy(O.SendMessage).was.called_with(O, "FS_ORDER_FULFILLED", {orderID=777, orderType="personal", customer="Bob-Silvermoon",
      recipeID=4444, itemID=211111, quality=3, tip=500000, consortiumCut=50000, commission=450000, rewards={}, rewardsValue=0, time=1000, charKey="Me-Silvermoon"})
  end)
  it("detects personal order arrivals after a baseline", function()
    local t = {profession=7, professionName="Tailoring"}
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})}))   -- first sighting is the baseline
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})}))
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=0})}))
    assert.same({{profession=7, professionName="Tailoring", count=2, delta=2}}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=2})}))
  end)
end)
```

`tests/orders/claim_click_only_spec.lua`: read every `.lua` file in 1a's `read_toc("FabricationStation.toc").files`. Then assert:
- `C_CraftingOrders.ClaimOrder(` occurs in exactly one file, `Modules/Orders.lua`, inside `function Orders:ClaimBest`.
- `:ClaimBest(` occurs outside `Modules/Orders.lua` only in `UI/OrdersPanel.lua`, on a line inside a `SetScript("OnClick"` block. Track the enclosing `SetScript("OnClick", function` … `end)` by line numbers.

Until Task 8 adds the button, the second assertion holds trivially: no caller exists yet.

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/orders/board_spec.lua tests/orders/claim_click_only_spec.lua`
Expected: FAIL (`attempt to call method 'OnBoardShown' (a nil value)`)

- [ ] **Step 3: Implement the functions listed under Interfaces in `Modules/Orders.lua`**

The live set and the snapshot are keyed by `orderID`. The snapshot stores the full `OrderView` (plain tables only). `GetClaimedOrder` normalizes `C_CraftingOrders.GetClaimedOrder()`. `ClaimBest` builds `claim` from `GetOrderClaimInfo(profession).claimsRemaining` and `GetClaimedOrder() ~= nil`. `OnFulfillClicked` stores the pending fulfilment. Its quality is `GetItemCraftedQualityByItemInfo(outputItemHyperlink)`, or `nil` when there is no link. Personal counts persist in `db.global.ordersState[charKey].personalCounts`; a profession with no stored count records a baseline and produces no arrival.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/orders && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

`/reload`, open a profession at a crafting-orders table, and open the Personal and Patron tabs. Then `/dump #FabricationStationDB.global.ordersSnapshot.orders`: the count equals the number of orders seen. Also record whether `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS` fired at login: `/etrace`, or a temporary print in the handler that you remove before committing.

- [ ] **Step 6: Commit**

```bash
git add Modules/Orders.lua tests/orders/board_spec.lua tests/orders/claim_click_only_spec.lua .luacheckrc
git commit -m "feat: capture order board, snapshot, claim best order, fulfilment and personal counts"
```

### Task 6: Ledger store, queries, weekly and per-recipe profit, benchmarks

**Files:**
- Create: `Modules/Ledger.lua`
- Modify: `FabricationStation.toc` (`Modules\Ledger.lua` after `Modules\Orders.lua`), `.luacheckrc` (`C_DateAndTime`)
- Test: `tests/ledger/ledger_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:Now()`, `ns.FS:CharKey()`, `ns.Msg.LEDGER_CHANGED`; 1a default `db.global.ledger = { entries = {} }`; `C_DateAndTime.GetSecondsUntilWeeklyReset()`.
- Produces:
  - `Ledger:Settings()` with defaults `{benchmarkMinSamples = 3, keepDays = 365}` in `db.global.settings.ledger`.
  - `Ledger:Add(entry)` (contract; fills `time = Now()` and `charKey = CharKey()` when missing; rejects a `type` outside `craft|sale|commission` or a non-integer `amount` with `error`; sends `ns.Msg.LEDGER_CHANGED`).
  - `Ledger:Query(filter) -> {LedgerEntry}` (contract; `filter = {type?, since?, before?, recipeID?, charKey?, customer?}`; newest first).
  - `Ledger:Prune(now)`.
  - `Ledger:WeekStart(now) -> number`.
  - `Ledger:Weekly(now, weeks) -> { {weekStart, income, cost, profit, incomplete} }` (newest first).
  - `Ledger:ByRecipe(filter) -> { [recipeID] = {income, cost, profit, n, incomplete} }`.
  - `Ledger.Percentile(sorted, p) -> number`.
  - `Ledger:Benchmark(recipeID, quality) -> {median, p25, p75, n}|nil` (contract; `quality == nil` means all qualities).
- Profit rule: only `sale` and `commission` entries count. `income = amount`, `cost = entry.cost or 0`, and `incomplete` counts entries whose `cost == nil`. `craft` entries are cost-basis records and are excluded. NPC reward values are shown but are not gold income.
- `WeekStart(now) = now + GetSecondsUntilWeeklyReset() - 604800`.
- Percentile is linear interpolation on sorted values: `h = (n-1)p + 1`, and the result is rounded to an integer with `math.floor(x + 0.5)`. The benchmark uses the gross `tip` of commission entries and returns nil when `n < benchmarkMinSamples`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Ledger store", function()
  local ns, L
  local W = 1495200   -- WeekStart(2000000) with 100000 s until reset
  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100000 end } })
    P2.load(ns, {"Modules/Ledger.lua"}); L = ns.FS:GetModule("Ledger")
  end)
  it("computes the weekly reset boundary", function() assert.equal(W, L:WeekStart(2000000)) end)
  it("aggregates weekly and per-recipe profit", function()
    L:Add({time=W+100, type="commission", amount=450000, cost=30000, recipeID=4444, tip=500000, quality=3})
    L:Add({time=W+200, type="sale", amount=950000, cost=150000, recipeID=4444, quantity=5})
    L:Add({time=W-100, type="sale", amount=100000, recipeID=5555, quantity=1})
    L:Add({time=W+300, type="craft", amount=-30000, recipeID=4444, quantity=2})
    assert.same({ {weekStart=W, income=1400000, cost=180000, profit=1220000, incomplete=0},
                  {weekStart=W-604800, income=100000, cost=0, profit=100000, incomplete=1} }, L:Weekly(2000000, 2))
    assert.same({ [4444] = {income=1400000, cost=180000, profit=1220000, n=2, incomplete=0},
                  [5555] = {income=100000, cost=0, profit=100000, n=1, incomplete=1} }, L:ByRecipe({}))
  end)
  it("queries newest first and rejects bad entries", function()
    L:Add({time=1, type="craft", amount=-1}); L:Add({time=2, type="sale", amount=5})
    assert.equal(2, L:Query({})[1].time); assert.equal(1, #L:Query({type="craft"}))
    assert.has_error(function() L:Add({type="loot", amount=1}) end)
    assert.has_error(function() L:Add({type="sale", amount=1.5}) end)
  end)
  it("benchmarks tips by percentile", function()
    for _, t in ipairs({300, 100, 400, 200}) do L:Add({type="commission", amount=t, tip=t, recipeID=4444, quality=3}) end
    assert.same({median=250, p25=175, p75=325, n=4}, L:Benchmark(4444, 3))
    assert.same({median=250, p25=175, p75=325, n=4}, L:Benchmark(4444, nil))
    assert.is_nil(L:Benchmark(4444, 2)); assert.is_nil(L:Benchmark(9999, 3))
  end)
  it("prunes entries older than keepDays", function()
    L:Add({time=2000000 - 366*86400, type="sale", amount=1}); L:Add({time=2000000 - 10, type="sale", amount=1})
    L:Prune(2000000); assert.equal(1, #L:Query({}))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ledger/ledger_spec.lua`
Expected: FAIL (`Modules/Ledger.lua` not found)

- [ ] **Step 3: Implement the `Ledger` functions listed under Interfaces in `Modules/Ledger.lua`**

The store is `db.global.ledger = {entries = {}, costBasis = {}, nameIndex = {}}`: `entries` comes from 1a's defaults, `costBasis` and `nameIndex` are created lazily (guard `entries` with `or {}` too). `OnEnable` calls `Prune(Now())`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ledger && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Modules/Ledger.lua tests/ledger/ledger_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: add Ledger store with weekly, per-recipe profit and tip benchmarks"
```

### Task 7: Ledger capture — craft cost basis, order commissions, AH sale mail

**Files:**
- Modify: `Modules/Ledger.lua`, `.luacheckrc` (`GetInboxInvoiceInfo`, `GetInboxHeaderInfo`, `TakeInboxMoney`, `AutoLootMailItem`, `AUCTION_SOLD_MAIL_SUBJECT`)
- Test: `tests/ledger/capture_spec.lua`

**Interfaces:**
- Consumes: 1a `Scanner:GetSchematic(recipeID)` (`reagentSlots = { {slotIndex, required, quantity, reagents = {itemID,...} (lowest quality rank first), kind, dataSlotIndex, dataSlotType, automatic, currencyID?} }`; currency-only slots set `currencyID` and leave it out of `reagents`); 1a `Prices:Get`; `Enum.TradeskillSlotDataType.ModifiedReagent` (= 2, in 1a's stubs); `Orders:GetClaimedOrder() -> OrderInput|nil` (Task 5); `ns.Msg.ORDER_FULFILLED` / `FulfilledOrder` (Task 5). `craftingReagents` has 1a's verified shape `{ {reagent = {itemID?, currencyID?}, dataSlotIndex, quantity} }` and covers only `ModifiedReagent` slots, whether Blizzard's UI or 1b's `Queue:CraftNext` (via `Scanner:ToCraftingReagentInfo`) made the call; the post-hook sees both.
- Produces:
  - `Ledger:OnCraftRecipe(recipeID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration)` (post-hook on `C_TradeSkillUI.CraftRecipe`).
  - `Ledger:OnCraftResult(event, data)` (`TRADE_SKILL_ITEM_CRAFTED_RESULT`).
  - `Ledger:CostOfCraft(recipeID, craftingReagents, provided, returned) -> cost, incomplete, estimated`.
  - `Ledger:OnOrderFulfilled(event, fulfilled)`.
  - `Ledger:OnTakeMoney(index)` (post-hook on `TakeInboxMoney` and `AutoLootMailItem`).
  - `Ledger.ItemNameFromLink(link) -> string|nil`.
  - `Ledger:ResolveItemName(name) -> itemID|nil, ambiguous`.
- `CostOfCraft` rules:
  - A reagent's itemID is `r.reagent.itemID`; entries with only `r.reagent.currencyID` cost 0. Slots with `currencyID` and empty `reagents` are skipped.
  - For each schematic slot, use the `craftingReagents` entries whose `dataSlotIndex == slot.dataSlotIndex`. If there are none and the slot is required:
    - a slot whose `dataSlotType ~= Enum.TradeskillSlotDataType.ModifiedReagent` is a fixed reagent that Blizzard never passes, so it costs exactly `slot.reagents[1] × slot.quantity` (not estimated);
    - a `ModifiedReagent` slot with no entry uses `slot.reagents[1] × slot.quantity` and marks the cost `estimated`.
    Optional and finishing slots with no entry add nothing.
  - The paid quantity per item is `max(0, used - provided[itemID])`.
  - Returned reagents are subtracted at their price.
  - Any used item without a price makes the cost `incomplete`, and the cost then sums only the priced items.
- The craft entry is `{type="craft", amount=-cost, itemID=data.itemID, quantity=data.quantity, quality=data.craftingQuality, recipeID, ref=orderID, operationID=data.operationID, incomplete?}`. A non-order craft that is not incomplete also adds to `costBasis[itemID] = {totalCost += cost, totalQty += quantity, recipeID}` and sets `nameIndex[ItemNameFromLink(data.hyperlink)] = {itemID, ambiguous}`, where `ambiguous` becomes true once a second itemID has been seen for that name.
- Multicraft (same rule as 1b's Queue Task 12): a result whose `operationID` equals the last recorded craft's `operationID` is an extra from the same cast. It adds its `quantity` to that craft entry (and to `costBasis.totalQty` when that entry fed the cost basis), records no new cost and does not consume a cast.
- `ItemNameFromLink` strips `|A...|a` atlas markup and trims spaces from the text inside `[...]`.
- The commission entry is `{type="commission", amount=commission, tip, recipeID, itemID, quality, customer, orderType, ref=orderID, rewardsValue, cost = Σ -amount of craft entries with ref == orderID, or nil when none}`.
- Sale entries:
  - From the invoice: `invoiceType == "seller"` gives `{type="sale", source="invoice", itemName, itemID, ambiguous, quantity=count or 1, amount=bid-consignment, buyer=playerName, deposit, recipeID=costBasis.recipeID, cost=floor(totalCost/totalQty*quantity+0.5) or nil}`.
  - Subject fallback, used only when the invoice is nil: the subject matches a pattern built from `AUCTION_SOLD_MAIL_SUBJECT`, or the literal `"Auction successful: %s"` when that global is missing. It produces `{source="subject", itemName=<capture>, quantity=1, amount=header money}`.
  - Dedupe signature: `itemName|bid or money|count|playerName|floor(daysLeft*1440)`, kept for the session. Header money of 0 is skipped.
- `OnEnable` sets up, each body wrapped with `ns.FS:Wrap("Ledger", …)`; the three `hooksecurefunc` hooks are installed once per session (guard `self.hooked`, as 1a's Prices does, because `hooksecurefunc` cannot be undone and a module can be disabled and re-enabled), and each hook body returns early while `not self:IsEnabled()`:
  - `hooksecurefunc(C_TradeSkillUI, "CraftRecipe", …)`
  - `hooksecurefunc("TakeInboxMoney", …)` and `hooksecurefunc("AutoLootMailItem", …)`
  - the event `TRADE_SKILL_ITEM_CRAFTED_RESULT`
  - the message `ns.Msg.ORDER_FULFILLED`

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Ledger capture", function()
  local ns, L, inv, hdr, claimed, op
  local LINK = "|cff1eff00|Hitem:211111::|h[Potion of Foo |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r"
  before_each(function()
    inv, hdr, claimed, op = {}, {}, nil, 0
    ns = P2.boot({ GetInboxInvoiceInfo = function(i) return unpack(inv[i] or {}, 1, 12) end,
                   GetInboxHeaderInfo = function(i) return unpack(hdr[i] or {}, 1, 12) end,
                   AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s",
                   C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end } })
    local price = {[100]=10000, [101]=15000, [200]=5000}
    P2.fake_module(ns, "Prices", { Get = function(_, id) return {value = price[id]} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return { reagentSlots = {
      {slotIndex=1, required=true, quantity=3, reagents={100,101}, kind="basic", dataSlotIndex=1, dataSlotType=2},   -- quality slot: in craftingReagents
      {slotIndex=2, required=true, quantity=2, reagents={200}, kind="basic", dataSlotIndex=2, dataSlotType=1} } } end })   -- fixed reagent: never passed
    P2.fake_module(ns, "Orders", { GetClaimedOrder = function() return claimed end })
    P2.load(ns, {"Modules/Ledger.lua"}); L = ns.FS:GetModule("Ledger")
  end)
  local function craft(orderID)
    op = op + 1
    L:OnCraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, orderID, false)
    L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=2, craftingQuality=3, hyperlink=LINK, operationID=op,
      resourcesReturned={ {reagent={itemID=100}, quantity=1} }})
  end
  it("stores craft cost basis at craft time", function()
    craft(nil)
    local e = L:Query({type="craft"})[1]
    assert.same({-30000, 2, 3, 4444, 211111}, {e.amount, e.quantity, e.quality, e.recipeID, e.itemID})
    assert.is_nil(e.incomplete)
    assert.same({totalCost=30000, totalQty=2, recipeID=4444}, ns.FS.db.global.ledger.costBasis[211111])
    assert.equal(211111, (L:ResolveItemName("Potion of Foo")))
  end)
  it("adds a multicraft extra with the same operationID to the same craft entry", function()
    craft(nil)
    L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, craftingQuality=3, hyperlink=LINK, operationID=op})
    local e = L:Query({type="craft"}); assert.equal(1, #e)
    assert.same({3, -30000}, {e[1].quantity, e[1].amount})
    assert.same({totalCost=30000, totalQty=3, recipeID=4444}, ns.FS.db.global.ledger.costBasis[211111])
  end)
  it("is reached through the CraftRecipe post-hook", function()
    C_TradeSkillUI.CraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
    L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, craftingQuality=3, hyperlink=LINK, operationID=99})
    assert.equal(1, #L:Query({type="craft"}))
  end)
  it("subtracts customer-provided reagents and records the commission", function()
    claimed = {orderID=777, provided={[200]=2}}
    craft(777)
    assert.equal(-20000, L:Query({type="craft"})[1].amount)
    assert.is_nil(ns.FS.db.global.ledger.costBasis[211111])
    L:OnOrderFulfilled("FS_ORDER_FULFILLED", {orderID=777, orderType="personal", customer="Bob-Silvermoon", recipeID=4444, itemID=211111,
      quality=3, tip=500000, consortiumCut=50000, commission=450000, rewards={}, rewardsValue=0, time=1000, charKey="Me-Silvermoon"})
    local c = L:Query({type="commission"})[1]
    assert.same({450000, 20000, 500000, 777}, {c.amount, c.cost, c.tip, c.ref})
  end)
  it("records an AH sale from the invoice with cost basis", function()
    craft(nil); craft(nil)   -- costBasis 60000 / 4
    inv[1] = {"seller", "Potion of Foo", "Buyer", 1000000, 0, 20000, 50000, 0, 0, 0, 5, false}
    hdr[1] = {nil, nil, "Auction House", "Auction successful: Potion of Foo (5)", 970000, 0, 29.5, 0}
    L:OnTakeMoney(1)
    local s = L:Query({type="sale"})[1]
    assert.same({950000, 5, 75000, 4444, 211111, "invoice"}, {s.amount, s.quantity, s.cost, s.recipeID, s.itemID, s.source})
  end)
  it("ignores a second take of the same mail", function()
    inv[1] = {"seller", "Potion of Foo", "Buyer", 1000000, 0, 20000, 50000, 0, 0, 0, 5, false}
    hdr[1] = {nil, nil, "Auction House", "x", 970000, 0, 29.5, 0}
    L:OnTakeMoney(1); L:OnTakeMoney(1); assert.equal(1, #L:Query({type="sale"}))
  end)
  it("records a sale of an uncrafted item as incomplete", function()
    inv[2] = {"seller", "Mystery Ore", nil, 40000, 0, 0, 2000, 0, 0, 0, 1, true}
    hdr[2] = {nil, nil, "Auction House", "x", 38000, 0, 10, 0}
    L:OnTakeMoney(2)
    local s = L:Query({type="sale"})[1]
    assert.is_nil(s.itemID); assert.is_nil(s.cost); assert.equal(38000, s.amount)
    assert.equal(1, L:Weekly(1000, 1)[1].incomplete)
  end)
  it("falls back to the English subject and ignores purchases", function()
    inv[3] = {"buyer", "Thing", "Seller", 5000, 0, 0, 0, 0, 0, 0, 1, false}; hdr[3] = {nil, nil, "Auction House", "Auction won: Thing", 0, 0, 30, 1}
    hdr[4] = {nil, nil, "Auction House", "Auction successful: Potion of Foo", 950000, 0, 29, 0}
    L:OnTakeMoney(3); L:OnTakeMoney(4)
    local s = L:Query({type="sale"}); assert.equal(1, #s)
    assert.same({"subject", "Potion of Foo", 950000, 1}, {s[1].source, s[1].itemName, s[1].amount, s[1].quantity})
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ledger/capture_spec.lua`
Expected: FAIL (`attempt to call method 'OnCraftRecipe' (a nil value)`)

- [ ] **Step 3: Implement the capture functions listed under Interfaces in `Modules/Ledger.lua`**

The pending craft context `{recipeID, craftingReagents, orderID, provided, castsLeft = numCasts}` is set by `OnCraftRecipe`. `provided` comes from `Orders:GetClaimedOrder()` when its `orderID` matches. `OnCraftResult` first checks the multicraft rule (same `operationID` as the last recorded craft entry, which is kept outside the context so it still matches after the context is cleared). Otherwise it uses the context and decrements `castsLeft`, then clears the context at 0. A result with no context and no matching `operationID` records nothing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ledger && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

- Craft one item. `/dump FabricationStationDB.global.ledger.entries[#FabricationStationDB.global.ledger.entries]` shows a `craft` entry with a negative amount.
- Collect one "Auction successful" mail with Open All. It produces exactly one `sale` entry.
- Note in the commit message whether a multicraft proc arrived as a second `TRADE_SKILL_ITEM_CRAFTED_RESULT` with the same `operationID` (the rule shared with 1b's Queue), or was already included in the first result's `quantity`.

- [ ] **Step 6: Commit**

```bash
git add Modules/Ledger.lua tests/ledger/capture_spec.lua .luacheckrc
git commit -m "feat: capture craft cost basis, order commissions and AH sales from mail"
```

### Task 8: OrdersPanel — additions to Blizzard's crafting-orders list

**Files:**
- Create: `UI/OrdersPanel.lua`
- Modify: `FabricationStation.toc` (`UI\OrdersPanel.lua` after 1b's `UI\Tooltips.lua`), `.luacheckrc` (`ScrollUtil`; 1a already lists `CreateFrame`, `GameTooltip`, `UIParent`)
- Test: `tests/ui/orders_panel_spec.lua`

**Interfaces:**
- Consumes: `Orders:GetView`, `GetLiveViews`, `IsHidden`, `Settings`, `GetBestClaimable`, `ClaimBest`, `RISK_LABELS`; `Customers:Get`, `IsBlocked`; `Ledger:Benchmark`; 1a `ns.UI.FormatMoney` (`"--"` for nil); 1a `ns.FS:SafeCall` (disables the named module if enabled, logs, sends `FS_MODULE_FAILED`, prints once), `ns.FS:LogError`, `ns.FS.failedModules`; `ns.Msg`.
- Produces:
  - Shared table `ns.UI.OrdersPanel` (`ns.UI` is created by 1a's `UI/Util.lua`) with pure functions:
    - `RowModel(view, customer, filters) -> {profit, score, riskCount, riskText, highlight = "blocked"|"vip"|"repeat"|nil, dimmed, estimated}`. `profit = view.net` and `score` are copper or nil. `riskText` is the risk labels joined with `"\n"` for the tooltip. `dimmed = Orders:IsHidden(view, filters)`. `estimated = view.flags and view.flags.estimated or false` (1b's "no calibration" flag); the score cell then shows `~` before the money so an estimate never looks certain. Highlight precedence:
      1. `"blocked"`: `view.risks` contains `blockedCustomer`, which is group-aware, or `customer.tags.blocked`
      2. `"vip"`: `customer.tags.VIP`
      3. `"repeat"`: `#customer.orders >= 2`
    - `BestText(itemText, view, benchmark) -> string`, formatted `"<itemText> · net <FormatMoney(view.net)> · tip vs your median <+N%|-N%|n/a>"`, with `N = floor((tip/median - 1) * 100 + 0.5)`.
    - `Guard(moduleName, fn, ...)`, which calls `ns.FS:SafeCall(moduleName, fn, ...)` only while that module is enabled.
  - Three modules, each a normal toggleable module (1a's `settings.modules[<Name>]`, default on, listed in 1a's `"modules"` options group and in Task 13's group; changed only through `ns.FS:SetModuleEnabled`):
    - `OrdersRowAddons`: own overlay and cell frames, anchored to Blizzard rows and parented to an own container that clips children and is anchored over `OrderList.ScrollBox`.
    - `OrdersSidePanel`: own frame anchored `TOPLEFT` to `ProfessionsFrame` `TOPRIGHT` (+2, 0), width 220. It holds:
      - the header `"FabricationStation"`
      - one checkbox per risk (label `RISK_LABELS[risk]`, bound to `filters.hideRisks[risk]`) plus `"Hide unscored"`
      - the claims-remaining text
      - the `"Claim Best Order"` button, whose `SetScript("OnClick", ...)` is the only caller of `Orders:ClaimBest()`
      - the best-order line from `BestText`
      - the claim-result line from `CRAFTINGORDERS_CLAIM_ORDER_RESPONSE`: `"Claimed — open it from the order list"`, or `"Claim failed (<result>)"`.
    - `OrderViewWarning`: own fontstring frame anchored above `ProfessionsFrame.OrdersPage.OrderView`, showing `"Blocked customer: <name>"` in red or `"VIP customer · <n> previous orders"` in gold.
- Hooks, installed once per session per module through the late-attachment pattern in Global Constraints (they cannot be removed; while a module is disabled `Guard` makes its bodies no-ops), with every body run through `Guard`:
  - `hooksecurefunc(ProfessionsFrame.OrdersPage, "ShowOrders"|"ShowBuckets")`. Bucket view hides cells.
  - `ScrollUtil.AddAcquiredFrameCallback` / `AddReleasedFrameCallback` on the ScrollBox. Rows with no `elementData.option.orderID` get no cells.
  - `BrowseFrame:HookScript("OnShow"|"OnHide")` shows and hides the panel.
  - `hooksecurefunc(OrderView, "SetOrder")` for the warning.
  - Messages `ns.Msg.ORDERS_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED` refresh the visible cells.
- A missing hook target means that module calls `ns.FS:LogError("<Module>", "hook target missing: <path>")`, prints `"FabricationStation: <module> disabled (Blizzard UI changed)"` once and calls `:Disable()` (not `SetModuleEnabled`, so the stored setting stays on and the hook is retried next session).
- Row colours: VIP overlay `(1, 0.82, 0, 0.18)`; blocked `(1, 0.1, 0.1, 0.25)` plus a warning icon; dimmed (filtered out) uses an own black overlay at alpha `0.55`.
- Cells, in this order: profit (net), score, and a risk icon showing `riskCount` with a `GameTooltip` of `riskText`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("OrdersPanel", function()
  local ns, P, W
  before_each(function()
    ns, W = P2.boot()
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/OrdersPanel.lua"})
    P = ns.UI.OrdersPanel
  end)
  it("builds a row model with highlight and dimming", function()
    local v = {orderType="public", net=250000, score=200000, risks={"expiringSoon","blockedCustomer"}}
    local m = P.RowModel(v, {orders={{},{}}, tags={VIP=true}}, {hideRisks={expiringSoon=true}, orderTypes={public=true}})
    assert.same({250000, 200000, 2, "Expiring soon\nBlocked customer", "blocked", true},
      {m.profit, m.score, m.riskCount, m.riskText, m.highlight, m.dimmed})   -- blockedCustomer risk (group-aware) wins over VIP
    local ok = {orderType="public", net=1, score=1, risks={}}
    local f = {hideRisks={}, orderTypes={public=true}}
    assert.equal("vip", P.RowModel(ok, {orders={}, tags={VIP=true}}, f).highlight)
    assert.equal("repeat", P.RowModel(ok, {orders={{},{}}, tags={}}, f).highlight)
    assert.is_nil(P.RowModel(ok, nil, f).highlight); assert.is_false(P.RowModel(ok, nil, f).dimmed)
  end)
  it("disables only the failing addition", function()
    local rows, side = ns.FS:GetModule("OrdersRowAddons"), ns.FS:GetModule("OrdersSidePanel")
    P.Guard("OrdersRowAddons", function() error("boom") end)
    assert.is_false(rows:IsEnabled()); assert.is_true(side:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.OrdersRowAddons)
    local errs = ns.FS.db.global.diagnostics.errors; assert.equal("OrdersRowAddons", errs[#errs].source)
    assert.same({"FS_MODULE_FAILED", "OrdersRowAddons"}, {W.messages[#W.messages][1], W.messages[#W.messages][2]})
    local called = false; P.Guard("OrdersRowAddons", function() called = true end)
    assert.is_false(called)
  end)
  it("formats the best-order line with the tip benchmark", function()
    local money = ns.UI.FormatMoney(250000)
    assert.equal("Potion · net " .. money .. " · tip vs your median +25%",
      P.BestText("Potion", {net=250000, tip=500000}, {median=400000, p25=1, p75=1, n=5}))
    assert.equal("Potion · net " .. money .. " · tip vs your median n/a", P.BestText("Potion", {net=250000, tip=500000}, nil))
  end)
end)
```

(The test relies on 1a's `SafeCall` disabling the named module on error, which needs the modules enabled; `P2.load` runs 1a's `W.boot()`. The caller passes `itemText`: the hyperlink when it is cached, otherwise `tostring(itemID)`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/orders_panel_spec.lua`
Expected: FAIL (`UI/OrdersPanel.lua` not found)

- [ ] **Step 3: Implement `UI/OrdersPanel.lua` as specified under Interfaces**

Frames are created only in `OnEnable` or the first hook call, never at file load. Do not assign any field on a Blizzard frame. Keep `rowFrame → cells` in a weak-keyed own table.

- [ ] **Step 4: Run tests and lint**

Run: `busted tests/ui/orders_panel_spec.lua tests/orders/claim_click_only_spec.lua && luacheck .`
Expected: PASS (the click-only test now finds exactly one `ClaimBest(` caller, inside the button's `OnClick`).

- [ ] **Step 5: In-game check**

1. Open orders at a table with `/console taintLog 1` set.
2. Check that profit, score and risk cells line up with rows while scrolling.
3. Tag a customer VIP from `/run` and check that the row turns gold.
4. Toggle a filter and check that matching rows dim.
5. Click Claim Best Order, then Blizzard's Start Order and Craft buttons, and check that each still works.
6. Turn off each of the three modules in Settings › Modules (1a's group) and check that its addition disappears after `/reload`.
7. `Logs/taint.log` has no `FabricationStation` entries for Blizzard_Professions.

- [ ] **Step 6: Commit**

```bash
git add UI/OrdersPanel.lua tests/ui/orders_panel_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: add score/profit/risk columns, customer highlight, filters and Claim Best Order to crafting orders"
```

### Task 9: Personal-order arrival alert (sound + toast)

**Files:**
- Create: `UI/OrderAlert.lua`
- Modify: `FabricationStation.toc` (`UI\OrderAlert.lua` after `UI\OrdersPanel.lua`), `.luacheckrc` (`PlaySound`, `SOUNDKIT`)
- Test: `tests/ui/order_alert_spec.lua`

**Interfaces:**
- Consumes: `ns.Msg.PERSONAL_ORDER_ARRIVED` (`professionName, count, delta`; Task 5); `SOUNDKIT`/`PlaySound` defaults from the Task 1 stub additions.
- Produces: module `OrderAlert` with:
  - `OrderAlert:Settings()`, defaults `db.global.settings.alerts = {personalOrderSound = true, personalOrderToast = true, sound = "RAID_WARNING", toastSeconds = 8}`
  - `OrderAlert.ToastText(professionName, count) -> string`
  - `OrderAlert:OnArrived(event, professionName, count, delta)`, which plays `PlaySound(SOUNDKIT[sound] or SOUNDKIT.RAID_WARNING)` and shows the own toast frame (top-centre of `UIParent`, fades after `toastSeconds`; created on first use).

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("OrderAlert", function()
  local ns, A, played
  before_each(function()
    played = {}
    ns = P2.boot({ PlaySound = function(id) played[#played+1] = id end })
    P2.load(ns, {"UI/OrderAlert.lua"}); A = ns.FS:GetModule("OrderAlert")
    stub(A, "ShowToast")
  end)
  it("formats toast text", function()
    assert.equal("New personal crafting order: Tailoring (2 waiting)", A.ToastText("Tailoring", 2))
    assert.equal("New personal crafting order: Tailoring (1 waiting)", A.ToastText("Tailoring", 1))
  end)
  it("plays the sound and shows the toast per settings", function()
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 2, 1)
    assert.same({8959}, played); assert.stub(A.ShowToast).was.called_with(A, "New personal crafting order: Tailoring (2 waiting)")
    A:Settings().personalOrderSound = false; A:Settings().personalOrderToast = false
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 3, 1)
    assert.same({8959}, played); assert.stub(A.ShowToast).was.called(1)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/order_alert_spec.lua`
Expected: FAIL (`UI/OrderAlert.lua` not found)

- [ ] **Step 3: Implement `UI/OrderAlert.lua`**

`OnEnable` registers `ns.Msg.PERSONAL_ORDER_ARRIVED` with `ns.FS:Wrap("OrderAlert", ...)`. `ShowToast(text)` builds or reuses the toast frame. Settings live in `db.global.settings.alerts` (created lazily).

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/order_alert_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

Have a second account or a friend place a personal order while you are away from a crafting table. The sound plays and the toast shows. Record in the commit message whether the count event fired away from the table (see the Review Focus unverified list).

- [ ] **Step 6: Commit**

```bash
git add UI/OrderAlert.lua tests/ui/order_alert_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: alert with sound and toast when a personal crafting order arrives"
```

### Task 10: Orders tab

**Files:**
- Create: `UI/Tabs/Orders.lua`
- Modify: `FabricationStation.toc` (`UI\Tabs\Orders.lua` after 1b's `UI\Tabs\Queue.lua`, before `UI\Tabs\Settings.lua`)
- Test: `tests/ui/orders_tab_spec.lua`

**Interfaces:**
- Consumes: 1a `MainWindow:RegisterTab(id, def)` (`def = {label, icon, order, build(container), refresh(container)?, phase}`; returns false on a duplicate id or missing `label`/`order`/`build`; `build` runs once and `refresh` on every select, both `pcall`ed by MainWindow), 1a `MainWindow:RefreshTab(id)` (no-op unless that tab is selected and the window shown); 1a `ns.UI.FormatAge`, `ns.UI.FormatMoney`; `Orders:GetSnapshot`, `Filter`, `Settings().filters`, `RISK_LABELS`; `ns.UI.OrdersPanel.RowModel` (Task 8; looked up at call time because `UI\OrdersPanel.lua` loads later in the TOC); `Customers:Get`; `Ledger:Benchmark`.
- Produces:
  - `ns.UI.OrdersTab.Model(snapshot, filters, now) -> {header = "Orders seen <FormatAge(now - snapshot.time)> ago on <charKey>"|"No orders seen yet", rows = { {orderID, type, item, customer, tip, net, score, risks, expiresIn} }}`. Rows are filtered and sorted by `Orders:Filter`.
  - Module `"OrdersTab"` with `coreModule = true` (like 1a's `SettingsTab`, so it is not listed as a user toggle). Its `OnInitialize` calls `ns.FS:GetModule("MainWindow"):RegisterTab("orders", {label = "Orders", icon = "Interface\\Icons\\INV_Misc_Note_06", order = 40, phase = 2, build, refresh})`. The tab id is lowercase (1a convention).
  - The tab UI: a filter checkbox row (the same `filters` table as the side panel) and a `WowScrollBoxList` with columns Type, Item, Customer, Tip, Net, Score, Risk, Expires, using `RowModel` highlight colours. A row tooltip shows `Ledger:Benchmark(recipeID, minQuality)` as `"Your tips: median <m> (p25 <a>, p75 <b>, n=<n>)"`. `OrdersTab:OnEnable` registers `ns.Msg.ORDERS_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED` (wrapped with `ns.FS:Wrap("OrdersTab", ...)`) to call `MainWindow:RefreshTab("orders")`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders tab", function()
  local ns, T, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/OrdersPanel.lua", "UI/Tabs/Orders.lua"})
    T = ns.UI.OrdersTab
  end)
  it("registers at order 40", function()
    assert.same({"Orders", 40, 2}, {reg.orders.label, reg.orders.order, reg.orders.phase})
  end)
  it("formats the snapshot age with 1a's FormatAge", function()
    assert.equal("Orders seen <1m ago on Me-Silvermoon", T.Model({time=970, charKey="Me-Silvermoon", orders={}}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
  it("builds header and filtered rows", function()
    local snap = {time=400, charKey="Me-Silvermoon", orders={
      {orderID=1, orderType="public", itemID=5, score=10, net=10, tip=20, risks={}, expiresAt=5000},
      {orderID=2, orderType="npc", itemID=6, score=50, net=50, tip=0, risks={"expiringSoon"}, expiresAt=1500}}}
    local m = T.Model(snap, {hideRisks={expiringSoon=true}, orderTypes={public=true, npc=true}}, 1000)
    assert.equal("Orders seen 10m ago on Me-Silvermoon", m.header)
    assert.equal(1, #m.rows); assert.same({1, "public", 4000}, {m.rows[1].orderID, m.rows[1].type, m.rows[1].expiresIn})
    assert.equal("No orders seen yet", T.Model({orders={}}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/orders_tab_spec.lua`
Expected: FAIL (`UI/Tabs/Orders.lua` not found)

- [ ] **Step 3: Implement `UI/Tabs/Orders.lua` (model functions, registration, `build`/`refresh` from the Interfaces block)**

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/orders_tab_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

On a character that has not opened the order board, `/fs` → Orders shows the last snapshot with its "seen … ago on …" header. Filters hide flagged rows.

- [ ] **Step 6: Commit**

```bash
git add UI/Tabs/Orders.lua tests/ui/orders_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Orders tab showing the saved order board"
```

### Task 11: Customers tab

**Files:**
- Create: `UI/Tabs/Customers.lua`
- Modify: `FabricationStation.toc` (`UI\Tabs\Customers.lua` after `UI\Tabs\Orders.lua`)
- Test: `tests/ui/customers_tab_spec.lua`

**Interfaces:**
- Consumes: 1a `MainWindow:RegisterTab`, `MainWindow:RefreshTab`, `ns.UI.FormatMoney`; `Customers:Search`, `Get`, `GetGroup`, `SetNote`, `SetTag`, `Link`, `Unlink`, `Export`, `NormalizeName`.
- Produces:
  - `ns.UI.CustomersTab.ListModel(records) -> { {nameRealm, orders = n, tipsTotal, lastSeen, tagsText, linkedTo} }`, where `tagsText` is the sorted tags joined with `", "`.
  - `ns.UI.CustomersTab.LinkInput(text) -> nameRealm|nil, err`, which normalizes through `Customers:NormalizeName`, returns `err = "empty"` for blank input, and passes `Link` errors through.
  - Module `"CustomersTab"` (`coreModule = true`) whose `OnInitialize` calls `MainWindow:RegisterTab("customers", {label = "Customers", order = 50, phase = 2, icon = "Interface\\Icons\\INV_Misc_GroupNeedMore", build, refresh})`.
  - The tab UI:
    - a search box that calls `Search` on text change
    - a list with columns Name, Orders, Tips, Last seen, Tags
    - a detail pane with the order history (date, item, quality, tip), a notes multi-line edit box saved on focus lost, VIP and Blocked check buttons, a custom tag add field with removable tag chips, a "Linked to" edit box with Link/Unlink buttons, and the linked alts list from `GetGroup`
    - an "Export" button that opens an own dialog with a read-only, pre-selected edit box containing `Export(visible names)`
  - `CustomersTab:OnEnable` registers `ns.Msg.CUSTOMERS_CHANGED` (wrapped with `ns.FS:Wrap("CustomersTab", ...)`) to call `MainWindow:RefreshTab("customers")`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Customers tab", function()
  local ns, T, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "UI/Tabs/Customers.lua"}); T = ns.UI.CustomersTab
  end)
  it("registers at order 50", function() assert.same({"Customers", 50}, {reg.customers.label, reg.customers.order}) end)
  it("builds list rows", function()
    local rows = T.ListModel({ {nameRealm="Bob-Silvermoon", orders={{},{}}, tipsTotal=7, lastSeen=9, tags={blocked=true, VIP=true}} })
    assert.same({nameRealm="Bob-Silvermoon", orders=2, tipsTotal=7, lastSeen=9, tagsText="VIP, blocked"}, rows[1])
  end)
  it("normalizes link input", function()
    assert.equal("Bob-Silvermoon", (T.LinkInput(" Bob ")))
    assert.same({nil, "empty"}, {T.LinkInput("  ")})
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/customers_tab_spec.lua`
Expected: FAIL (`UI/Tabs/Customers.lua` not found)

- [ ] **Step 3: Implement `UI/Tabs/Customers.lua` as specified under Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/customers_tab_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

1. Fulfil one order; the customer appears with the item, quality and tip.
2. Tag the customer Blocked and link an alt. Back at the order board, an order from the alt shows the red highlight and the OrderView warning.
3. Export produces CSV text you can copy.

- [ ] **Step 6: Commit**

```bash
git add UI/Tabs/Customers.lua tests/ui/customers_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Customers tab with search, notes, tags, alt links and export"
```

### Task 12: Ledger tab and Dashboard widgets

**Files:**
- Create: `UI/Tabs/Ledger.lua`, `UI/OrdersWidgets.lua`
- Modify: `FabricationStation.toc` (`UI\Tabs\Ledger.lua` after `UI\Tabs\Customers.lua`; `UI\OrdersWidgets.lua` after `UI\OrderAlert.lua`, so after 1b's `UI\Tabs\Dashboard.lua`)
- Test: `tests/ui/ledger_tab_spec.lua`

**Interfaces:**
- Consumes: 1a `MainWindow:RegisterTab`, `MainWindow:RefreshTab(id)`, `ns.UI.FormatMoney/FormatAge`; 1b `Dashboard:RegisterWidget(id, def)` with `def = {order, title, build = function(frame) end, refresh = function(frame) end}` (1b stores `def.id = id`, same id replaces; 1b's `BuildAll` isolates a widget whose `build`/`refresh` errors, and 1b's phase-1 widgets use orders 10/20/30); `Ledger:Weekly`, `ByRecipe`, `Query`, `Benchmark`, `WeekStart`; `Orders:GetSnapshot`.
- Produces:
  - `ns.UI.LedgerTab.RecipeRows(byRecipe) -> { {recipeID, income, cost, profit, n, incomplete} }`, sorted by profit descending.
  - `ns.UI.LedgerTab.BenchmarkRows(entries) -> { {recipeID, quality, median, p25, p75, n} }`. Built from distinct `(recipeID, quality)` pairs of commission entries, calling `Ledger:Benchmark` for each and skipping nil results. Sorted by recipeID, then quality.
  - Module `"LedgerTab"` (`coreModule = true`) whose `OnInitialize` calls `MainWindow:RegisterTab("ledger", {label = "Ledger", order = 60, phase = 2, icon = "Interface\\Icons\\INV_Misc_Coin_02", build, refresh})`. The UI has three sections:
    - weekly summary for 8 weeks (income, cost, profit, plus `"<n> without cost basis"` when `incomplete > 0`)
    - the per-recipe table
    - an entries list (time, type, item, amount, customer) and the benchmark table
  - `LedgerTab:OnEnable` registers `ns.Msg.LEDGER_CHANGED` (wrapped) to call `MainWindow:RefreshTab("ledger")`.
  - `ns.UI.OrdersWidgets.OpenOrdersModel(snapshot, now) -> {total, personal, bestScore|nil, age|nil}`, where `age` is `now - snapshot.time` (the widget shows it with `ns.UI.FormatAge`).
  - `ns.UI.OrdersWidgets.GoldThisWeekModel(weekly) -> {profit, income, incomplete}`.
  - Module `"OrdersWidgets"` (`coreModule = true`) whose `OnInitialize` calls `ns.FS:GetModule("Dashboard"):RegisterWidget("openOrders", {order = 40, title = "Open orders", build, refresh})` and `RegisterWidget("goldThisWeek", {order = 50, title = "Gold this week", build, refresh})`. 1b's Dashboard only refreshes on its own three messages, so `OrdersWidgets:OnEnable` registers `ns.Msg.ORDERS_CHANGED` and `ns.Msg.LEDGER_CHANGED` (wrapped) to call `MainWindow:RefreshTab("dashboard")`, which re-runs every widget's `refresh` when the Dashboard is visible.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Ledger tab and widgets", function()
  local ns, reg, widgets
  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end } }); reg, widgets = {}, {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function(_, id, def) widgets[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/Tabs/Ledger.lua", "UI/OrdersWidgets.lua"})
  end)
  it("registers tab and widgets", function()
    assert.same({"Ledger", 60}, {reg.ledger.label, reg.ledger.order})
    assert.same({40, "Open orders", 50, "Gold this week"}, {widgets.openOrders.order, widgets.openOrders.title, widgets.goldThisWeek.order, widgets.goldThisWeek.title})
  end)
  it("sorts recipe rows by profit", function()
    local rows = ns.UI.LedgerTab.RecipeRows({ [1] = {income=5, cost=0, profit=5, n=1, incomplete=0}, [2] = {income=9, cost=1, profit=8, n=1, incomplete=0} })
    assert.same({2, 1}, {rows[1].recipeID, rows[2].recipeID})
  end)
  it("builds benchmark rows from commission history", function()
    local L = ns.FS:GetModule("Ledger")
    for _, t in ipairs({100, 200, 300}) do L:Add({type="commission", amount=t, tip=t, recipeID=4444, quality=3}) end
    L:Add({type="commission", amount=1, tip=1, recipeID=4444, quality=2})
    assert.same({ {recipeID=4444, quality=3, median=200, p25=150, p75=250, n=3} }, ns.UI.LedgerTab.BenchmarkRows(L:Query({type="commission"})))
  end)
  it("models the dashboard widgets", function()
    local W = ns.UI.OrdersWidgets
    assert.same({total=2, personal=1, bestScore=50, age=600},
      W.OpenOrdersModel({time=400, orders={ {orderType="personal", score=50}, {orderType="public", score=nil} }}, 1000))
    assert.same({total=0, personal=0}, W.OpenOrdersModel({orders={}}, 1000))
    assert.same({profit=7, income=9, incomplete=1}, W.GoldThisWeekModel({ {weekStart=0, income=9, cost=2, profit=7, incomplete=1} }))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/ledger_tab_spec.lua`
Expected: FAIL (`UI/Tabs/Ledger.lua` not found)

- [ ] **Step 3: Implement `UI/Tabs/Ledger.lua` and `UI/OrdersWidgets.lua` as specified under Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/ledger_tab_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Ledger.lua UI/OrdersWidgets.lua tests/ui/ledger_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Ledger tab and open-orders / gold-this-week dashboard widgets"
```

### Task 13: Phase-2 settings group and acceptance pass

**Files:**
- Create: `UI/OrdersOptions.lua`
- Modify: `FabricationStation.toc` (`UI\OrdersOptions.lua` after `UI\OrdersWidgets.lua`), `tests/integration/load_all_spec.lua` (1a-owned: add the phase-2 module names to its "enables every module" list)
- Test: `tests/ui/orders_options_spec.lua`

**Interfaces:**
- Consumes: 1a `ns.FS:RegisterOptions(key, group)` (adds `group` to the options table as `args[key]`; after init it also notifies AceConfigRegistry); 1a `ns.FS:SetModuleEnabled(name, enabled)` and `db.global.settings.modules`; `Orders:Settings()`, `Ledger:Settings()`, `OrderAlert:Settings()`; modules `OrdersRowAddons`, `OrdersSidePanel`, `OrderViewWarning`. Existing top-level option keys to avoid: 1a `general` (10), `prices` (20), `modules` (90), `diagnostics` (95); 1b `crafting`.
- Produces: `ns.UI.OrdersOptions.Build() -> AceConfig group`, registered at file load as `ns.FS:RegisterOptions("orders", Build())` with `name = "Orders & Ledger"`, `order = 40`. It has four subgroups:
  - **Order scoring**:
    - `lowTipMargin`, `knowledgePointValue`, `moxieValue` as range inputs in gold, stored as copper (`get` divides by 10000, `set` multiplies and floors)
    - `expiringSoonSeconds` in minutes
    - `claimMinScore` in gold
    - one toggle per `claimBlockingRisks` key
  - **Crafting-orders window**: toggles `rows`, `sidePanel` and `orderViewWarning` for modules `OrdersRowAddons`, `OrdersSidePanel` and `OrderViewWarning`. `get` returns `settings.modules[name] ~= false`; `set` calls `ns.FS:SetModuleEnabled(name, value)` (which stores the boolean in `settings.modules`, enables or disables now, and clears `failedModules[name]` on enable). These are shortcuts to the same switches 1a's `"modules"` group shows.
  - **Alerts**: `personalOrderSound`, `personalOrderToast`.
  - **Ledger**: `benchmarkMinSamples` (1–20), `keepDays` (30–1095).

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders options", function()
  local ns, g
  before_each(function()
    ns = P2.boot()
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
      "UI/OrdersPanel.lua", "UI/OrderAlert.lua", "UI/OrdersOptions.lua"})
    g = ns.UI.OrdersOptions.Build()
  end)
  it("edits copper settings in gold", function()
    local opt = g.args.scoring.args.lowTipMargin
    assert.equal(10, opt.get()); opt.set(nil, 12.5)
    assert.equal(125000, ns.FS:GetModule("Orders"):Settings().lowTipMargin)
  end)
  it("toggles a crafting-orders addition module through 1a's SetModuleEnabled", function()
    local opt = g.args.panel.args.rows
    assert.is_true(opt.get()); opt.set(nil, false)
    assert.is_false(ns.FS.db.global.settings.modules.OrdersRowAddons)
    assert.is_false(ns.FS:GetModule("OrdersRowAddons"):IsEnabled()); assert.is_false(opt.get())
  end)
  it("registers the group and is listed beside 1a's module toggles", function()
    local args = ns.FS:GetOptionsTable().args
    assert.equal("Orders & Ledger", args.orders.name)
    assert.is_truthy(args.modules.args.OrdersRowAddons); assert.is_truthy(args.modules.args.Ledger)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/orders_options_spec.lua`
Expected: FAIL (`UI/OrdersOptions.lua` not found)

- [ ] **Step 3: Implement `UI/OrdersOptions.lua` as specified under Interfaces**

Also extend the module list in 1a's `tests/integration/load_all_spec.lua` ("enables every module without logging errors") with `Customers, Orders, Ledger, OrdersRowAddons, OrdersSidePanel, OrderViewWarning, OrderAlert, OrdersTab, CustomersTab, LedgerTab, OrdersWidgets`, so the whole TOC (1a + 1b + phase 2) must boot cleanly against the stubs.

- [ ] **Step 4: Run the full suite and lint**

Run: `busted && luacheck .`
Expected: all specs PASS, `0 warnings / 0 errors`

- [ ] **Step 5: In-game acceptance (spec §7 checklist)**

Run these in one session with `/console taintLog 1`:
1. Public (drill into a bucket), Guild, Personal and Patron tabs each show profit, score and risk cells.
2. Claim Best Order claims the top unflagged order with one click and is disabled while an order is claimed.
3. Craft and fulfil it: the Customers tab shows the customer, the Ledger has `craft` and `commission` entries, and the Dashboard "Gold this week" goes up.
4. Collect an AH sale mail: one `sale` entry.
5. A personal order arrival plays the sound and shows the toast.
6. `/reload` on an alt: the Orders tab shows the snapshot with its age.
7. Disable FabricationStation: Blizzard's crafting-orders UI looks and works as before.
8. `taint.log` has no FabricationStation lines.

- [ ] **Step 6: Commit**

```bash
git add UI/OrdersOptions.lua tests/ui/orders_options_spec.lua tests/integration/load_all_spec.lua FabricationStation.toc
git commit -m "feat: add Orders & Ledger settings group"
```

---

## Self-review notes

- **Spec coverage (§7, §5.1, §5.3):**
  - Order scoring with rewards, quality and concentration: Tasks 3–4
  - Risk flags (all five): Task 4
  - Filters: Tasks 4, 8, 10
  - Claim Best (one click per claim): Tasks 5, 8, with the structural test in Task 5
  - Snapshot: Task 5
  - Customers capture, tags, links, search and export: Tasks 1–2, 11
  - Highlight and blocked warning in Blizzard's list: Task 8
  - Ledger commissions, AH mail sales, cost basis, weekly and per-recipe profit: Tasks 6–7, 12
  - Benchmarks: Tasks 6, 12
  - Alerts: Tasks 5, 9
  - Tabs: Tasks 10–12
  - Dashboard widgets: Task 12
  - Toggleable, self-disabling additions: Tasks 8, 13
- **Names checked across tasks:**
  - `OrderInput.provided` is used by Tasks 4 and 7.
  - `Orders:GetClaimedOrder` is defined in Task 5 and used in Task 7.
  - The `FulfilledOrder` fields are the same in Tasks 1, 5 and 7.
  - `ns.UI.OrdersPanel.RowModel` is defined in Task 8 and used in Task 10.
  - Settings keys are identical in Tasks 3, 6, 9 and 13. Module on/off state is 1a's `settings.modules[<Name>]` everywhere (Tasks 8, 13); there is no `settings.ordersPanel`.
- **Reconciled against 1a/1b:** test harness (1a `install_wow_stubs`/`load_addon`/`load_files`/`W.boot`, wrapped by `tests/helpers/phase2.lua`); `SafeCall`/`Wrap`/`LogError` semantics; `ns.UI.FormatMoney`/`FormatAge`; `ns.Msg` names (two added to `Core/Bus.lua` in Task 1); 1a DB defaults and `settings.modules` + `SetModuleEnabled`; lowercase tab ids and 1a's `RegisterTab` def; 1b `Dashboard:RegisterWidget` def; 1b `RecipeResult` fields and flags (incl. `estimated`; `ingenuityValue` is points and unused); Midnight `CraftingReagentInfo` (`reagent.itemID`, ModifiedReagent slots only) and 1a schematic slot fields; 1b's multicraft `operationID` rule; 1a GameData `Define/Get` and `MoxieCurrency`; 1a TOC load-order convention. Files outside phase 2 that phase 2 modifies: `Core/Bus.lua`, `tests/helpers/wow_stubs.lua` (Task 1), `tests/integration/load_all_spec.lua` (Task 13).
