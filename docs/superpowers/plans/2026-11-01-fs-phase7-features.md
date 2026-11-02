# FabricationStation Phase 7 — Competitive Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the 14 phase 7 items in `.superpowers/sdd/phase7-scoping/scope.md`: orders across characters, patron
reward pricing, batch order prep, ready alerts, a sale log and restock gates, a craft log with golden-fixture export,
an optional reagent optimizer, craft lists, intermediate crafts, a gathering plan with bank pull and merchant buy, a
chat-request inbox and key bindings.

**Architecture:** One saved-data migration (3: one order board per character). Everything else is new lazy tables or
new optional fields. New modules: `SaleLog`, `CraftLog`, `CraftLists`, `Intermediates`, `ChatInbox` (toggleable),
`ReadyAlerts`, `MerchantBuy`, `BankPull` (toggleable UI modules), and the core registrars `FeatureLines` and
`Bindings`. One new pure Math file (`Math/Optionals.lua`). Every protected or item-moving call sits in exactly one
function that is referenced only from an `OnClick` handler; key bindings click FabricationStation's own buttons.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.1.5, Interface 120105), Ace3 (AceAddon, AceEvent, AceDB, AceLocale,
AceConfig), Auctionator API v1, busted 2.3, luacheck.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` §9c (phase 7 scope), plus §3 (design rules),
§10 (out of scope), §11 (golden fixtures) and §12 (error isolation; migrations never wipe data). **Scope and rulings:**
`.superpowers/sdd/phase7-scoping/scope.md` (binding). **Sources and feasibility per item:**
`reports/Feature gaps 2026-11-01.md` (the V*/C* ids below). **Binding cross-phase names:**
`docs/superpowers/plans/2026-10-30-fs-interface-contract.md`. A task that adds or changes a contract item updates the
contract in the same task (a new `**[phase 7 Task N]**` bullet in the owning section).

## Global Constraints

- Retail only (Midnight 12.x, `## Interface: 120105`). Every WoW API this plan adds is feature-tested
  (`type(X) == "function"`, pcall'd) with a fallback that reads as "unknown" (nil), never 0. Each unverified one is in
  the list below and has a `P7-` checklist line.
- **Test command** (repo root; the path has a space, so quote it):
  `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" ~/.luarocks/bin/busted`.
  - The workspace directory is chosen when execution starts.
  - Its `bin/` holds a `lua` → LuaJIT shim. Copy `.superpowers/sdd/2026-10-30-fs-phase4-social-release/bin/lua`. Specs
    that shell out to `lua` must get Lua 5.1 semantics; the system `lua` is 5.5 and must not be used.
  - Focused runs: `... busted tests/path/x_spec.lua`.
  - Every task ends with the full suite green. The baseline is HEAD 78b16fc, 3321 successes.
- **CI runs PUC Lua 5.1.5** (`.github/workflows/ci.yml`, `leafo/gh-actions-lua` 5.1.5). So:
  - no LuaJIT-only code or tests: no `bit`, `ffi`, `jit`, `goto`, `table.new`, `\u{...}` escapes, hex floats or
    integer division;
  - no timing assertion whose measured span includes boot, file loading or fixture setup.
- **Lint:** `luacheck .` reports 0 warnings and 0 errors. New WoW globals go into `.luacheckrc` `read_globals` in the
  task that first uses them; the two binding globals and the `BINDING_*` strings go into `globals` (Task 19).
- **Locale:** `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" lua tools/check_locale.lua` prints `locale keys OK`.
  - Every new user-visible string is one whole `ns.L` key (AceLocale application `"FabricationStation"`; the key is
    the English text; `L["..."] = true` in `Locales/enUS.lua`; only `enUS.lua` is edited).
  - Whole sentences with `%s`/`%d`, never joined pieces; a plural is two keys (`"%d craft"` / `"%d crafts"`).
  - A context comment is a trailing `-- ...` after `= true` when a key is ambiguous.
  - A file that uses call-time lookup keeps it. Log text and error codes carry `-- locale: joined (...)` as today.
- **English output:** no existing spec's expected English string is edited unless a task names the change.
- **Error isolation:** every event, message, hook, timer and script handler runs through `ns.FS:Wrap(source, fn)` /
  `ns.FS:SafeCall`. A toggleable module wraps with its module name (an error turns only it off). A core registrar uses
  a log-only source (`"Bindings:Run"`, `"FeatureLines:<id>"`).
- **Owned timers:** only `ns.FS:Debounce` keys (each module's keys cancelled in its `OnDisable`). No `C_Timer.NewTicker`.
  `tests/integration/phase4_spec.lua`'s disable test stays green, and Task 20 adds the same test for the new modules.
- **Read-only data:** nothing is written while `ns.FS.dbIsNewer`. Every new writer has a `writable()` or
  `ns.Util.SettingsAccessor` guard and a dbIsNewer spec that asserts `db.global` is unchanged
  (`ns.Util.DeepCopy(ns.FS.db.global, 30)` before and after), not just one field.
- **No automation (rule 3, scope ruling):** nothing crafts, claims, posts, buys, sends chat or moves items without a
  player click or key press. Protected and item-moving calls are listed under "Protected actions" below, each with a
  structural spec. No `C_AuctionHouse` post, bid, buy or cancel call anywhere: the sale log only post-hooks
  Blizzard's own calls.
- **Own frames only (rules 2 and 7):** new panels are FabricationStation frames anchored beside Blizzard frames
  (`SetPoint` relative to them); no field of a Blizzard frame or table is written; hooks are `hooksecurefunc` /
  `HookScript` post-hooks; no `StaticPopupDialogs` entries; no `UIDropDownMenu`.
- **Unknown is nil, never 0.** Unknown money, counts, rates and ages read as `nil` and show as `?` or "unknown".
- **No TSM, no Syndicator, no out-of-game notifications, no Classic** (§10). Auctionator stays the price source; only
  `Prices` touches it (rule 5).
- **Modules do not depend on UI files:** `Core/` and `Modules/` load before `UI/Util.lua`. Module code looks other
  modules up at call time (`ns.FS:GetModule(name, true)`).
- Peer and chat text goes through `ns.Social.Util.EscapePipes`. The main window keeps its 516 px minimum.
- `Protocol.VERSION` stays `1` and the wire format does not change.
- TDD: failing test, run (RED), implement, run (GREEN). Self-review the diff. Conventional commits end with the
  session's `Co-Authored-By` line. Never push, tag or publish.
- In specs, `_G.Name = value` for WoW globals.
- **In-game checks** become `P7-N` lines in a new `## Phase 7` section of `docs/in-game-checklist.md`, right before
  `## Not done here`, in the style of the P6 lines (a bold title, then steps and the expected result). Task 1 creates
  the section. The numbers are assigned below per task, so tasks never renumber each other.
- **TOC:** each task adds its files when it creates them, at the places named in File Structure.

## Review Focus

Five ways real use is most likely to break this, most likely first. Each has a test in the named task.

1. **Logging between two alts with the same profession after the upgrade.** A phase 6 save has one snapshot; after
   migration 3 and a board on the second alt, both boards are kept and each order is scored for the character that
   saw it. Tests: Task 1 `moves the phase 6 snapshot to its character's board`, `keeps both alts' boards when the
   second alt opens the same profession`, `rescores each board for its own character`.
2. **Pressing Retrieve again while the last move is still in flight** (server lag, a locked slot). Never more than the
   shortfall leaves the bank, and nothing moves while an item is on the cursor. Tests: Task 16 `moves nothing while
   the last move is in flight`, `never moves more than the shortfall over repeated presses`, `refuses while the cursor
   holds an item`.
3. **A reagent graph with a cycle or a long chain** (a transmute pair, a recipe that makes its own reagent). The
   resolution ends, never queues a cycle, and stops at depth 3. Tests: Task 14 `treats a reagent already on the path
   as buy only`, `stops at depth 3`, `evaluates at most 50 sub-recipes per resolution`.
4. **A merchant selling in stacks, or the player short of gold.** One click buys at least the missing count, rounded
   up to the merchant's stack, and never spends more than the gold on hand. Tests: Task 17 `rounds up to the
   merchant's stack size`, `buys nothing when the gold on hand is short`.
5. **Crafts FabricationStation did not start, and Multicraft extras.** A craft from Blizzard's own button is logged
   under the recipe actually crafted (not the last one FabricationStation saw, CraftSim's bug #1540), and an extra
   item adds to its own craft only. Tests: Task 9 `logs a craft from Blizzard's button under the crafted recipe`,
   `adds a Multicraft extra to the craft with the same operationID only`.

**Unverified API assumptions** (each step that relies on one says so; each has the named P7 line):
- `CraftingItemResultData` (payload of `TRADE_SKILL_ITEM_CRAFTED_RESULT`) has `multicraft`, `concentrationSpent`,
  `ingenuityRefund`, `hasIngenuityProc` besides the fields the Ledger already reads (Task 9, P7-16). Without one, that
  actual value is nil.
- `AUCTION_HOUSE_AUCTION_CREATED(auctionID)` fires after both `C_AuctionHouse.PostItem(item, duration, quantity, bid,
  buyout)` and `PostCommodity(item, duration, quantity, unitPrice)`, whose `item` is an `ItemLocation`
  (`C_Item.GetItemID(item)` still answers in the post-hook) (Task 6, P7-11).
- `C_AuctionHouse.GetNumOwnedAuctions()` / `GetOwnedAuctionInfo(i)` (`auctionID`, `itemKey.itemID`, `quantity`,
  `status` with `Enum.AuctionStatus.Active = 0`) after `OWNED_AUCTIONS_UPDATED` (Task 6, P7-10);
  `CancelAuction(ownedAuctionID)` then `AUCTION_CANCELED(auctionID)` (Task 6, P7-12).
- `GetInboxItem(index, attachment)` returns `name, itemID, texture, count`; `GetInboxHeaderInfo(index)` has `CODAmount`
  6th and `hasItem` 8th; `AUCTION_EXPIRED_MAIL_SUBJECT` is a `%s` format (Task 6, P7-9, P7-13).
- `C_CraftingOrders.RequestCrafterOrders(request)` with FabricationStation's own request and a
  `C_FunctionContainers.CreateCallback` callback refreshes `GetCrafterOrders()` without disturbing Blizzard's list
  (Task 5, P7-7). Without `C_FunctionContainers` the Refresh button is not shown.
- `FlashClientIcon()` exists (Task 5, P7-6).
- `Bindings.xml` `category="ADDONS"` lists the bindings under AddOns; a key press that calls `Button:Click()` on an
  addon button runs `C_CraftingOrders.ClaimOrder` and `C_TradeSkillUI.CraftRecipe` as a hardware event (Task 19, P7-28).
- `C_Container.UseContainerItem(bag, slot)` on a bank or warband slot moves the stack into the bags from an addon
  click while the bank is open; `SplitContainerItem` + `PickupContainerItem` places part of a stack; whether
  `CraftRecipe` already uses bank or warband reagents (Task 16, P7-24). `BankFrame` is the 12.x bank frame (P7-25).
- `C_MerchantFrame.GetItemInfo(index)` (else `GetMerchantItemInfo`), `GetMerchantItemID`, `GetMerchantItemMaxStack`,
  and that `BuyMerchantItem(index, quantity)` counts items, not purchase stacks (Task 17, P7-26).
- `CHAT_MSG_WHISPER_INFORM(text, target, ...)` names the target as `Name-Realm`; whisper text can be a secret value in
  instances (Task 18, P7-27).
- The Midnight knowledge currencies 3150–3160 (CurrencyTypes 70688) appear as patron rewards, and which knowledge
  items do (Task 2, P7-2).
- `CraftRecipe` accepts optional and finishing reagent infos built with `dataSlotIndex` from the cached schematic
  (Task 12, P7-20); the optional reagent effect amounts in `OptionalReagents` are the units `Stats.ApplyOptionals`
  expects (Task 11, P7-19).

---

## Decisions this plan states

### Saved data (migration 3; everything else lazy)

`schemaVersion` goes from 2 to 3. Only the order snapshot changes shape; every other addition is a new table created
on first write (never while `dbIsNewer`, damaged parts repaired, never wiped) or a new optional field.

| Key | Shape | Owner | Task |
|---|---|---|---|
| `orderBoards` **(migration 3)** | `{ [charKey] = { time, orders = { [orderID] = OrderView }, scopes = { ["<orderType>:<profession>"] = time } } }` | Orders | 1 |
| `ordersSnapshot` | removed by migration 3 (moved into `orderBoards`); dropped from `ns.DBDefaults` | — | 1 |
| `settings.orders` | adds `rewardCostLimits = { knowledge = copper?, moxie = copper? }` (absent = no limit), `claimBlockingRisks.rewardTooCostly = true`, `filters.characters = "all"\|"current"`, `filters.sort = "score"\|"expires"\|"character"` | Orders | 2, 3 |
| `settings.readyAlerts` | `{ concentrationFull = false, moxieThreshold = 0, cooldownReady = false, newOrdersFlash = false, newOrdersSound = false, personalOrderFlash = false, chat = true, sound = true }` | ReadyAlerts | 5 |
| `characters[charKey].mail` | `{ time, items = { [itemID] = count } }` (non-COD attachments) | Scanner | 6 |
| `auctionLog` | `{ listings = { [charKey] = { time, items = { [itemID] = qty } } }, events = { { time, kind = "post"\|"cancel"\|"expire", itemID, quantity, unitPrice?, charKey } } (cap 2000), seenMail = { [signature] = time } }` | SaleLog | 6 |
| `settings.saleLog` | `{ windowDays = 30, tooltip = true }` | SaleLog | 6 |
| `queue.restockMinProfit` | `{ [itemID] = copper per craft }` | Queue | 7 |
| `settings.crafting` | adds `restockCountMail = true`, `restockCountListed = true` (T7), `optionalMode = "simple"` (T11), `bankPullUseWarband = true` (T16) as `Recipes.DEFAULTS` keys | Recipes | 7, 11, 16 |
| `craftLog` | `{ nextID, entries = { CraftLogEntry } }` (cap 1000; `fixture` kept on the newest 100) | CraftLog | 9 |
| queue entries | adds optional `optionalItemIDs = { itemID }` (T12) and `parentID` (T14) | Queue | 12, 14 |
| `craftLists` | `{ nextID, lists = { CraftList } }` (at most 50 lists, 200 recipes each) | CraftLists | 13 |
| `intermediateChoices` | `{ [itemID] = "craft"\|"buy" }` (absent = the cheaper one) | Intermediates | 14 |
| `chatInbox` | `{ nextID, entries = { InboxEntry } }` (cap 100; 20 history lines each) | ChatInbox | 18 |
| `settings.chatInbox` | `{ dismissMinutes = 30, keepDays = 7, keepHistory = true }` | ChatInbox | 18 |

Shapes:
- `CraftLogEntry = { id, time, charKey, recipeID, orderID?, operationID?, applyConcentration, predicted = { quality,
  qualityChances, yield, concentrationCost?, multicraftValue?, resourcefulnessValue? } | nil, game = { quality,
  concentrationCost?, baseSkill?, bonusSkill?, baseDifficulty?, bonusDifficulty?, lowerSkillThreshold?,
  upperSkillTreshold? } | nil, actual = { quality?, quantity, baseQuantity?, multicraft (extra items, 0 = none),
  resourcesReturned = { [itemID] = qty }, concentrationSpent?, ingenuityRefund?, ingenuityProc? }, fixture = {
  reagents, calib, build } | nil }`.
- `CraftList = { id, name, recipes = { { recipeID, charKey?, quantity } }, rules = { minProfit?, minQuality?,
  concentration = "off"|"single"|"multi", useOptionals = false } }`.
- `InboxEntry = { id, time, seenBy, sender, kind, text, recipes = { { recipeID, name, link? } }, status =
  "open"|"replied"|"dismissed"|"expired", statusTime, history = { { time, dir = "in"|"out", text } } }`.

### Event sources

- **Sale log (Task 6).**
  - Posts: post-hooks on `C_AuctionHouse.PostItem` and `PostCommodity` queue `{ itemID, quantity, unitPrice }`
    (FIFO); `AUCTION_HOUSE_AUCTION_CREATED` confirms the oldest one as a `"post"` event and adds it to this
    character's listing. A pending post older than 60 s is dropped.
  - Listings: `OWNED_AUCTIONS_UPDATED` replaces this character's listing with the `Active` owned auctions. FS never
    calls `QueryOwnedAuctions`: Blizzard's Auctions tab does.
  - Cancels: post-hook on `C_AuctionHouse.CancelAuction(ownedAuctionID)` looks the auction up in the last owned list;
    `AUCTION_CANCELED(auctionID)` records the `"cancel"` event and lowers the listing.
  - Expiries: `MAIL_INBOX_UPDATE` (0.5 s debounce) scans the headers; a subject matching
    `AUCTION_EXPIRED_MAIL_SUBJECT` (English fallback `"Auction expired: %s"`) with an attachment gives an `"expire"`
    event (`GetInboxItem(i, 1)`'s itemID and count). Each mail counts once, across sessions: signature =
    `subject .. "|" .. itemID .. "|" .. count .. "|" .. floor((Now() - (30 - daysLeft) * 86400) / 3600)`, kept in
    `seenMail` 31 days. "Auction cancelled" mail is ignored (the cancel hook counted it).
  - Sales: the Ledger's `"sale"` entries (sold mail, phase 2). SaleLog records no sale itself; it reads
    `Ledger:Query({ type = "sale", since })`.
- **Craft log (Task 9).** A post-hook on `C_TradeSkillUI.CraftRecipe` in `Modules/CraftLog.lua` (the second allowed
  hook line; the structural spec is widened in Task 9) stores the pending craft and its predictions:
  `Recipes:FromCraftingReagentInfo` → `Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration)`
  and `Scanner:GetLiveOperationInfo(...)`. `TRADE_SKILL_ITEM_CRAFTED_RESULT` writes the entry from the first result
  of an `operationID` and adds later results of the same `operationID` as Multicraft extras.
  `UNIT_SPELLCAST_INTERRUPTED` (player, that recipe) drops the pending craft. `RecraftRecipe`, enchants
  (`data.isEnchant`) and salvage are not logged, as in the Ledger (Ruling P3).

### Protected actions

| Call | The only function that calls it | Referenced only from | Spec |
|---|---|---|---|
| `C_TradeSkillUI.CraftRecipe` | `Queue:CraftNext` (unchanged) | `OnClick` handlers; the binding clicks `FabricationStationCraftNextProxy` | `tests/queue/craft_spec.lua` |
| `C_CraftingOrders.ClaimOrder` | `Orders:ClaimBest` (unchanged) | the side panel claim button's `OnClick` in `UI/OrdersPanel.lua`; the binding calls `ns.UI.OrdersPanel.ClickClaim()`, which calls `:Click()` on that button | `tests/orders/claim_click_only_spec.lua` |
| `C_CraftingOrders.RequestCrafterOrders` | `Orders:RequestBoard` | the side panel Refresh button's `OnClick` | Task 5 |
| `BuyMerchantItem` | `MerchantBuy:Buy` | the merchant panel button's `OnClick` | Task 17 |
| `C_Container.UseContainerItem`, `SplitContainerItem`, `PickupContainerItem` | `BankPull:Step` | the bank panel button's `OnClick` | Task 16 |
| `ChatFrameUtil.SendTellWithMessage` (fills the edit box, sends nothing) | `ChatInbox:Reply` and the existing `ChatToast` Whisper | `OnClick` handlers and `FabricationStation_Binding("replyLatest")` | Task 18 |

`tests/helpers/click_only.lua` (Task 5) holds the tokenizer and the two checks every row uses: `only_inside(token,
path, functionHeader)` and `referenced_only_from_onclick(name, allowedPaths)`. Task 5 moves the tokenizer out of
`tests/orders/claim_click_only_spec.lua`, which then requires it (its cases are unchanged).

### Intermediate crafts (Task 14)

- `Intermediates.MAX_DEPTH = 3`: sub-crafts at most 3 levels below the craft being planned.
- **Cycle guard:** the resolution carries the set of itemIDs and recipeIDs on the path from the root. A reagent whose
  itemID, or whose producing recipe, is already on the path is buy-only for that branch (`cycle = true`).
- `MAX_NODES = 50` sub-recipe evaluations per resolution; past it every further reagent is buy-only
  (`truncated = true`). A per-resolution memo keyed `itemID .. ":" .. depth` evaluates a shared reagent once.
- A sub-craft is evaluated without concentration, at the quality the reagent item is (`FindRecipesForItem` quality),
  by the cheapest crafter of `WhoCanCraft`, with its own chosen reagent costs passed down as `reagentPrices`.
- Cost of one crafted item = `(reagentCost - (resourcefulnessValue or 0)) / expectedYield`; nil when any of these is
  unknown.

### Bank pull (Task 16)

While the bank is open (`Scanner.bankOpen`, out of combat, nothing on the cursor) `BankPull:Step()` may call only:
`C_Container.GetContainerNumSlots`, `GetContainerItemInfo`, `GetContainerNumFreeSlots`, `UseContainerItem`,
`SplitContainerItem`, `PickupContainerItem`, `C_Item.GetItemCount`, `C_Bank.CanViewBank(Enum.BankType.Account)`,
`GetCursorInfo`, `ClearCursor` (only to undo its own split when no free slot took it) and `InCombatLockdown`. One press
makes at most one move. Nothing runs on `BANKFRAME_OPENED` but showing the panel.

---

## File Structure

| Path | Responsibility (this plan) |
|---|---|
| `Core/Migrations.lua`, `Core/DB.lua` | Migration 3; `ordersSnapshot` leaves the defaults (Task 1) |
| `Modules/Orders.lua` | Boards per character (1); reward pricing and `rewardTooCostly` (2); `GetOrders` (3); new-order diff, `RequestBoard` (5) |
| `Data/OrderRewards.lua` | Knowledge and Moxie currencies (2) |
| `UI/OrdersOptions.lua` | Reward settings (2) |
| `UI/Tabs/Orders.lua` | All-characters tracker (3); multi-select and Shop selected (4) |
| `UI/OrdersPanel.lua` | Refresh button and new-order line (5); `ClickClaim` (19) |
| `Modules/Queue.lua`, `Modules/QueueCraft.lua` | Export of given entries (4); restock gates (7); optionals (12); `Add` `before`/`parentID` (14); gathering plan (15); `GetRequired` (16) |
| `Modules/Scanner.lua` | Mail snapshot (6); `OptionalReagentInfos` (12) |
| `Modules/SaleLog.lua` (new) | Module `SaleLog`: listings, posts, cancels, expiries, item stats (6, 8) |
| `Modules/CraftLog.lua` (new) | Module `CraftLog`: capture and summaries (9, 10) |
| `Math/Optionals.lua` (new) | `ns.Math.Optionals.Best` (11) |
| `Modules/CraftingData.lua`, `Modules/Recipes.lua` | `optionalSlots`, `opts.optionalItemIDs`, `BestOptionals` (11); `opts.reagentPrices` (14); new DEFAULTS keys (7, 11, 16) |
| `Modules/CraftLists.lua` (new) | Module `CraftLists` (13) |
| `Modules/Intermediates.lua` (new) | Module `Intermediates` (14) |
| `Modules/Social/ChatInbox.lua` (new) | Module `ChatInbox` (18) |
| `UI/ReadyAlerts.lua` (new) | Module `ReadyAlerts` and its options (5) |
| `UI/FeatureLines.lua` (new) | Core registrar `FeatureLines`: sale tooltip line (8), optionals lines (12), intermediates lines and action (14) |
| `UI/Tabs/Ledger.lua` | Section row: Profit, Auctions (8), Crafts (10) |
| `UI/Tabs/Queue.lua` | Restock min profit and held (7); section row Queue, Lists (13), Gather (15) |
| `UI/Tabs/Planner.lua` | Queue plan button (13) |
| `UI/BankPull.lua` (new) | Module `BankPull` (16) |
| `UI/MerchantBuy.lua` (new) | Module `MerchantBuy` (17) |
| `UI/Tabs/Requests.lua` (new) | Core registrar `RequestsTab`, tab `"requests"`, order 95 (18) |
| `UI/Bindings.lua` (new), `Bindings.xml` (new, repo root) | Core registrar `Bindings` (19) |
| `tools/export_math_fixtures.lua` (new), `tests/math/golden_spec.lua` (new), `tests/fixtures/math/index.lua` (new) | Golden fixtures (10) |
| `tests/helpers/click_only.lua` (new) | Structural checks (5) |
| `tests/helpers/wow_stubs.lua` | Inert fakes: `FlashClientIcon` (5), auction house and mail (6), container moves (16), merchant (17) |
| `Locales/enUS.lua`, `.luacheckrc`, `FabricationStation.toc` | Every task |
| `docs/in-game-checklist.md`, interface contract, `CHANGELOG.md`, `README.md` | Every task; CHANGELOG and README in Task 20 |

**TOC places:** `Math\Optionals.lua` after `Math\Profit.lua`; `Modules\SaleLog.lua`, `Modules\CraftLog.lua`,
`Modules\CraftLists.lua`, `Modules\Intermediates.lua` after `Modules\Onboarding.lua` in that order;
`Modules\Social\ChatInbox.lua` after `Modules\Social\ChatScan.lua`; `UI\Tabs\Requests.lua` after `UI\Tabs\Guild.lua`;
`UI\FeatureLines.lua`, `UI\ReadyAlerts.lua`, `UI\BankPull.lua`, `UI\MerchantBuy.lua`, `UI\Bindings.lua` at the end, in
that order. `Bindings.xml` is not listed in the TOC (the client loads it from the addon root); Task 19 adds it to the
release spec's shipped-files check.

**Options groups (key, order):** `readyAlerts` 65 "Alerts" (Task 5), `chatInbox` 82 "Request inbox" (Task 18);
`saleLog` settings go into the existing `orders` group ("Orders & Ledger", Task 8); the crafting keys into `crafting`.

## Contract changes (owned by this plan)

- SavedVariables layout: `orderBoards` replaces `ordersSnapshot` (migration 3); every lazy key in the table above.
- `Orders:GetSnapshot()` keeps its shape: the current character's board, else the most recently seen board (Task 1).
  New: `Orders:GetBoards()`, `Orders:GetOrders(filters)`, `Orders:RequestBoard()`, risk `rewardTooCostly` appended to
  `Orders.RISKS`, `OrderView.costPerReward`, `units` on valued rewards.
- Bus: `FS_ORDERS_NEW(charKey, count, orderType)` (Task 5); `FS_DATA_CHANGED` kind `"mail"` (Task 6; Recipes and the
  recipe scan ignore it like `"concentration"`); `FS_SALELOG_CHANGED` (Task 6); `FS_CRAFTLOG_CHANGED` (Task 9);
  `FS_INBOX_CHANGED` (Task 18).
- Recipes: `opts.optionalItemIDs` (a sixth cached key, sorted) and `RecipeResult.optionalAllocation` (Task 11);
  `opts.reagentPrices` (uncached, like `extraStats`, Task 14); `Recipes:BestOptionals` (Task 11).
- Queue: `ExportShoppingList(onRetry, opts)` (Task 4), `GetMissingForEntries` (4), restock status and min profit (7),
  `QueueEntry.optionalItemIDs` (12), `Add(entry, opts)` with `opts.before` and `entry.parentID` (14),
  `GetGatheringPlan` (15), `GetRequired` (16).
- Scanner: `ScanMail`, `GetMailCount` (6), `OptionalReagentInfos` (12).
- Tabs: `requests` order 95. Option groups `readyAlerts` 65, `chatInbox` 82.
- The two structural specs widen as Tasks 9 and 19 say; Task 5 adds `tests/helpers/click_only.lua`.

---
## Orders across characters (Tasks 1–5)

### Task 1: One order board per character (migration 3)

**Files:**
- Modify: `Core/Migrations.lua` (register 3), `Core/DB.lua` (drop `ordersSnapshot` from `ns.DBDefaults.global`)
- Modify: `Modules/Orders.lua` (the board section, 596-850: `snapshot_table`, `OnBoardShown`, `GetSnapshot`, `GetView`,
  `Rescore`, `update_order`; new `GetBoards`)
- Test: `tests/core/migrations_spec.lua` (new `describe("migration 3")`), `tests/core/db_spec.lua` (line 24),
  `tests/orders/board_spec.lua` (the 9 `ordersSnapshot` lines), `tests/ui/orders_tab_spec.lua:160`,
  `tests/ui/ledger_tab_spec.lua:571,593`
- Docs: contract (SavedVariables layout, Orders "as built"), `docs/in-game-checklist.md` (creates `## Phase 7`, P7-1)

**Rules (decided):**
- **Migration 3** (`Migrations.Register(3, fn(global))`):
  1. `old = rawget(global, "ordersSnapshot")`; not a table → set nothing but `global.ordersSnapshot = nil`.
  2. `global.orderBoards`: kept when a table, else `{}`.
  3. Owner: `old.charKey` when a non-empty string; else the `charKey` of the lowest-orderID view that has a non-empty
     string `charKey`; else none.
  4. With an owner and a non-empty `old.orders`: `boards[owner]` is created as `{ time = old.time, orders = {},
     scopes = {} }` when missing; every table view of `old.orders` whose orderID the board does not hold yet is moved
     in (an existing view wins).
  5. Without an owner and with a non-empty `old.orders`: `global.ordersSnapshotLegacy = old` (kept, read by nothing).
  6. `global.ordersSnapshot = nil`.
- **Boards at run time:** `board_for(charKey)` returns `orderBoards[charKey]` (created with `orders = {}, scopes = {}`
  on first write); while read-only, a session copy of the stored `orderBoards` (deep copy once, as today's
  `sessionSnapshot`).
  - `OnBoardShown(orderTypeEnum, orders, profession)`: changes only the current character's board (the in-scope views
    are replaced as today); sets `board.time = now` and `board.scopes[typeName .. ":" .. tostring(profession)] = now`;
    drops expired views from every board. The rule "a snapshot made by another character is started afresh" is gone.
  - `Orders:GetSnapshot()` keeps its contract shape `{ time, charKey, orders = { OrderView } }`: the current
    character's board when it has a `time`, else the board with the newest `time`; `{ orders = {} }` without boards.
  - `GetView(orderID)`: live, else the current character's board, else the other boards newest first.
  - `Rescore()`: one `BuildContext(charKey)` per board; live views use the current character's.
  - `update_order`: the board holding the order, the current character's first.
  - `Orders:GetBoards() -> { { charKey, time, orders = { OrderView } } }`: unexpired views sorted by orderID; boards
    sorted current character first, then `time` desc (nil last), then charKey. Stored tables, read-only.
- Boards of characters no longer in `Scanner:GetCharacters()` are kept.

**Interfaces:**
- Consumes: `Migrations.Register`, the existing view and context functions of Orders.
- Produces: `Orders:GetBoards()`; `db.global.orderBoards` (shape in "Saved data"); `GetSnapshot` unchanged for callers.

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/core/migrations_spec.lua
describe("migration 3", function()
  local function run(global) global.schemaVersion = 2; return ns.Migrations.Run(global) end
  it("moves the phase 6 snapshot to its character's board", function()
    local g = { ordersSnapshot = { time = 500, charKey = "Aria-Realm", orders = { [7] = { orderID = 7 } } } }
    assert.is_true((run(g)))
    assert.equals(3, g.schemaVersion); assert.is_nil(g.ordersSnapshot)
    assert.equals(500, g.orderBoards["Aria-Realm"].time); assert.equals(7, g.orderBoards["Aria-Realm"].orders[7].orderID)
  end)
  it("takes the owner from a view when the snapshot has no charKey", function()
    local g = { ordersSnapshot = { orders = { [9] = { orderID = 9, charKey = "Bren-Realm" }, [3] = { orderID = 3 } } } }
    run(g); assert.truthy(g.orderBoards["Bren-Realm"].orders[3])
  end)
  it("keeps an ownerless snapshot as ordersSnapshotLegacy", function()
    local old = { orders = { [3] = { orderID = 3 } } }
    local g = { ordersSnapshot = old }; run(g)
    assert.equal(old, g.ordersSnapshotLegacy); assert.same({}, g.orderBoards)
  end)
  it("keeps a board already present and never overwrites its views", function() --[[ board 8 kept, 7 added ]] end)
  it("removes the empty default snapshot and creates no board", function() --[[ { orders = {} } -> orderBoards {} ]] end)
  it("leaves a newer database alone", function() --[[ schemaVersion 4: "newer", ordersSnapshot untouched ]] end)
end)

-- tests/orders/board_spec.lua
it("keeps both alts' boards when the second alt opens the same profession", function()
  show_board("Me-Silvermoon", 7, { order(777) }); show_board("Alt-Silvermoon", 7, { order(888) })
  local boards = O:GetBoards()
  assert.equals(2, #boards); assert.equals("Alt-Silvermoon", boards[1].charKey)   -- current first
  assert.truthy(ns.FS.db.global.orderBoards["Me-Silvermoon"].orders[777])
end)
it("rescores each board for its own character", function()
  -- spy on Orders:BuildContext: called once with "Me-Silvermoon" and once with "Alt-Silvermoon"
end)
it("GetSnapshot falls back to the newest board when this character has none", function() end)
it("GetView finds an order on another character's board", function() end)
it("records the scope of every board shown", function()
  assert.equals(ns.FS:Now(), ns.FS.db.global.orderBoards["Me-Silvermoon"].scopes["public:7"])
end)
```
`show_board(charKey, profession, orders)` is a local helper in `board_spec.lua` that sets `UnitName` (the character
part of the key) and calls `O:OnBoardShown(0, orders, profession)`. The existing dbIsNewer case keeps its
`DeepCopy(ns.FS.db.global, 30)` comparison. The other `ordersSnapshot` lines in the listed specs read or seed
`orderBoards["Me-Silvermoon"]` instead; `db_spec.lua:24` asserts `assert.is_nil(g.ordersSnapshot)` and
`assert.is_nil(g.orderBoards)` (lazy).

- [ ] **Step 2: Run** `... busted tests/core/migrations_spec.lua tests/orders/board_spec.lua tests/core/db_spec.lua`.
  Expected: FAIL (no migration 3, `orderBoards` nil, `GetBoards` missing).
- [ ] **Step 3: Implement** migration 3 in `Core/Migrations.lua`, the defaults change in `Core/DB.lua`, and the board
  rules above in `Modules/Orders.lua`.
- [ ] **Step 4: Run** the focused specs, then the full suite. Expected: PASS, suite green.
- [ ] **Step 5: Docs.** Contract: `orderBoards` in the SavedVariables layout (with "[phase 7 Task 1] migration 3"),
  `GetBoards`, the new `GetSnapshot` rule. Create `## Phase 7` in the checklist with **P7-1. Upgrade keeps the last
  board, and alts keep their own.** First login after the update with a phase 6 save: no error, and the Orders tab
  shows the last board under the character that saw it. Then open the same profession's board on a second character:
  `/run local n=0 for _ in pairs(FabricationStationDB.global.orderBoards) do n=n+1 end print(n)` prints 2.
- [ ] **Step 6: Commit** `feat: keep one crafting-order board per character (migration 3)`.

---

### Task 2: Price patron rewards

**Files:**
- Modify: `Data/OrderRewards.lua`, `Modules/Orders.lua` (`SETTINGS_DEFAULTS`, `unit_value`, `ValueRewards`,
  `ScoreInput`, `RISKS`, `RISK_LABELS`), `UI/OrdersOptions.lua` (two limits and the unknown-rewards group),
  `UI/OrdersPanel.lua` (`M.Notes`: the cost-per-reward note), `Locales/enUS.lua`
- Test: `tests/data/order_rewards_spec.lua` (new), `tests/orders/score_spec.lua`, `tests/ui/orders_options_spec.lua`,
  `tests/orders/board_spec.lua` (claim)
- Docs: contract (Orders), checklist P7-2, P7-3

**Rules (decided):**
- **Gold per knowledge point** is the existing `settings.orders.knowledgePointValue` (default 500000, Settings > Orders
  & Ledger). No per-profession override (see the report: cut).
- **`Data/OrderRewards.lua`** (still build 70688): `currencies[3150..3160] = { kind = "knowledge", points = 1 }`
  (CurrencyTypes 70688 "Midnight <profession> Knowledge") and `currencies[3256..3266] = { kind = "moxie" }` (the
  `MoxieCurrency` values). `items` stays `{}` until P7-2 names the knowledge items. The header comment says which
  rows came from the cache and that items need the game.
- **Valued reward entries** gain `units`: `count * (entry.points or 1)` for kind `"knowledge"`, `count` for
  `"moxie"`, nil otherwise. `ValueRewards(rewards, orderID)` keeps its signature.
- **Cost per reward** in `ScoreInput`: `base = commission - reagentCost - (concentrationCharge or 0)` when
  `commission` and `reagentCost` are numbers, else nil. For each kind with `units > 0`:
  `view.costPerReward[kind] = base == nil and nil or (base >= 0 and 0 or math.floor(-base / units))`.
  `view.costPerReward = {}` when no reward has units.
- **Risk `rewardTooCostly`** (appended to `Orders.RISKS`, label `L["Reward costs too much"]`): any kind whose
  `costPerReward` is a number above `settings.rewardCostLimits[kind]` (a number ≥ 0; absent = no limit).
  `claimBlockingRisks.rewardTooCostly = true` by default (fill adds it to existing settings). The filter checkbox comes
  from `OrdersPanel.FilterChecks()` (built from `RISKS`).
- **Options** (`UI/OrdersOptions.lua`, under the existing reward values):
  - `L["Most you pay per knowledge point (gold)"]` and `L["Most you pay per Moxie (gold)"]`: empty = no limit
    (stores nil), else `ns.UI.ParseMoney` of gold; each change calls `Orders:ScheduleRescore()`.
  - Group `L["Unknown rewards"]`: one gold input per key of `db.global.ordersUnknownRewards` (at most 20, by `count`
    desc then key), named by `C_Item.GetItemNameByID` / `C_CurrencyInfo.GetCurrencyInfo().name` (else the key) and
    `L["seen on %d orders"]`; a value sets `rewardOverrides[key]`, empty removes it; then `ScheduleRescore()`.
    Description `L["Rewards FabricationStation could not value. Give one a value and orders with it are scored."]`.
  - Every control is disabled while `dbIsNewer`.
- **Note** (`M.Notes(view)`): `L["Pays %s per knowledge point"]` / `L["Pays %s per Moxie"]` with
  `ns.UI.FormatMoney`, only when the cost is a number above 0.

**Interfaces:**
- Produces: `OrderView.costPerReward = { knowledge = copper|nil, moxie = copper|nil }`; risk `"rewardTooCostly"`;
  `settings.orders.rewardCostLimits`; `units` on each valued reward.

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/data/order_rewards_spec.lua
it("lists the Midnight knowledge and Moxie currencies", function()
  local d = ns.GameData.Get("OrderRewards")
  for id = 3150, 3160 do assert.same({ kind = "knowledge", points = 1 }, d.currencies[id]) end
  for id = 3256, 3266 do assert.same({ kind = "moxie" }, d.currencies[id]) end
  assert.same({}, d.items); assert.equals(70688, ns.GameData.TableBuild("OrderRewards"))
end)

-- tests/orders/score_spec.lua (P2.raw_order; reagentCost from the fake Recipes result)
it("values a Midnight knowledge currency reward at knowledgePointValue", function()
  local v = score({ npcOrderRewards = { { currencyType = 3151, count = 2 } } })
  assert.equals(1000000, v.rewardsValue); assert.equals(2, v.rewards[1].units)
end)
it("flags rewardTooCostly when the order costs more per knowledge point than the limit", function()
  O:Settings().rewardCostLimits.knowledge = 200000
  local v = score({ tipAmount = 0, npcOrderRewards = { { currencyType = 3151, count = 1 } } }, { reagentCost = 300000 })
  assert.equals(300000, v.costPerReward.knowledge); assert.truthy(has_risk(v, "rewardTooCostly"))
end)
it("costs nothing per reward when the order pays for itself", function() --[[ costPerReward.knowledge == 0 ]] end)
it("leaves the cost per reward unknown when the reagent cost is unknown", function() --[[ nil, no risk ]] end)
it("sets no risk without a limit", function() end)
it("counts a reward override in the score of an unknown currency", function() end)

-- tests/orders/board_spec.lua
it("does not claim a rewardTooCostly order by default", function() end)

-- tests/ui/orders_options_spec.lua
it("sets and clears a reward override from the unknown rewards group", function() end)
it("stores no limit for an empty input and rescores after a change", function() end)
it("disables the reward limits while the saved data is read-only", function() end)
```

- [ ] **Step 2: Run** the three specs. Expected: FAIL (empty OrderRewards, no `units`, no risk).
- [ ] **Step 3: Implement** the data, the scoring rules, the options and the note.
- [ ] **Step 4: Run** focused, then full suite and `tools/check_locale.lua`. Expected: PASS, `locale keys OK`.
- [ ] **Step 5: Docs.** Contract: `RISKS` gains `rewardTooCostly` (last), `costPerReward`, `units`, the settings.
  **P7-2. Patron reward IDs.** On each crafting character's patron tab, `/dump C_CraftingOrders.GetCrafterOrders()[n].npcOrderRewards`
  for a few orders. Expected: a knowledge reward is either currency 3150–3160 (then nothing to add) or an item; report
  every item with its knowledge points for `OrderRewards.items`. **P7-3. Cost per knowledge point.** Set "Most you pay
  per knowledge point" to 50g. Expected: a patron order whose reagents cost more than its tip plus 50g per point shows
  "Reward costs too much", Claim Best Order skips it, and the row tooltip says "Pays …g per knowledge point".
- [ ] **Step 6: Commit** `feat: price patron rewards (knowledge and Moxie currencies, cost per reward limit)`.

---

### Task 3: Work-order tracker across characters

**Files:**
- Modify: `Modules/Orders.lua` (new `GetOrders`; `SETTINGS_DEFAULTS.filters.characters/sort`), `UI/Tabs/Orders.lua`
  (`COLUMNS`, `HIDE_ORDER`, `Tab.Model`, header, the two controls), `Locales/enUS.lua`
- Test: `tests/orders/board_spec.lua`, `tests/ui/orders_tab_spec.lua`
- Docs: contract (Orders, OrdersTab), checklist P7-4

**Rules (decided):**
- `Orders:GetOrders(filters) -> views, boardTimes`: views from `GetBoards()`; `filters.characters == "current"` keeps
  the current character's board only; otherwise every board, leaving out characters hidden in `settings.alts.hidden`
  while the Alts module is enabled. Then `Orders:Filter(views, filters)`, then the sort:
  - `"score"` (default): Filter's order (best first);
  - `"expires"`: `expiresAt` ascending, nil last, then orderID;
  - `"character"`: charKey, then Filter's order.
  `boardTimes = { [charKey] = time }`. The views are the stored tables (read-only).
- `Tab.Model(orders, boardTimes, filters, now) -> { header, headerTooltip, seen, total, rows }` replaces the snapshot
  argument. Rows add `character = view.charKey` and `age = now - boardTimes[view.charKey]`.
  - One board: the header stays `L["Orders seen %s ago on %s"]`.
  - Several: `L["Orders from %d characters"]`, plus `L["next expires in %s"]` after a dot when an order has an expiry.
  - `headerTooltip`: one line per board, `L["%s: %d orders, seen %s ago"]`.
  - `seen` is true when any board has a time.
- `COLUMNS` gains `{ key = "character", label = L["Character"], width = 80 }` after `type`;
  `HIDE_ORDER = { "character", "customer", "type" }`. The cell shows the short name (the realm is cut for the current
  realm, as the Queue tab does); the row tooltip adds `L["Seen %s ago on %s"]`.
- Controls (in the check bar, after the filter checks):
  - a button `L["Characters: all"]` / `L["Characters: this one"]` toggling `filters.characters`;
  - a button `L["Sort: best"]` / `L["Sort: expiring"]` / `L["Sort: character"]` cycling `filters.sort`.
  Both write `Orders:Settings().filters` (a session copy while read-only) and refresh.
- Add to Queue on another character's order queues it for that character (`QueueEntry` already copies
  `view.charKey`).

**Interfaces:**
- Consumes: `Orders:GetBoards()` (Task 1).
- Produces: `Orders:GetOrders(filters) -> { OrderView }, { [charKey] = time }`; `ns.UI.OrdersTab.Model(orders,
  boardTimes, filters, now)`; `filters.characters`, `filters.sort`. Task 4 adds the selection column to this layout.

- [ ] **Step 1: Write the failing tests** (`tests/ui/orders_tab_spec.lua` seeds two boards in
  `db.global.orderBoards`; `tests/orders/board_spec.lua` the getter):
  `lists every character's orders with a Character column`, `shows only the current character's board for "this one"`,
  `sorts by expiry with unknown expiry last`, `sorts by character, then best first`,
  `leaves hidden characters out while Alts is on`, `names each board's age in the header tooltip`,
  `hides the Character column first when the window is narrow` (`Tab.Layout(516).hidden.character == true`,
  `customer` still shown), `adds another character's order to the queue for that character`.
  Key assertion for the expiry sort:
  `assert.same({ 2, 3, 1 }, ids(O:GetOrders({ sort = "expires" })))` with expiresAt 300, 400, nil.
- [ ] **Step 2: Run.** Expected: FAIL (`GetOrders` missing, Model takes a snapshot).
- [ ] **Step 3: Implement** the getter, the model and the controls.
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** Contract entries. **P7-4. One list of every alt's orders.** Open boards on two characters.
  Expected: the Orders tab lists both with a Character column; "Characters: this one" shows only the logged-in one;
  "Sort: expiring" puts the soonest first; the header tooltip gives each board's age; an expired order is gone.
- [ ] **Step 6: Commit** `feat: work-order tracker across characters in the Orders tab`.

---

### Task 4: Batch order prep (selected orders → one shopping list)

**Files:**
- Modify: `Modules/Queue.lua` (new `GetMissingForEntries`), `Modules/QueueCraft.lua` (`ExportShoppingList(onRetry,
  opts)`), `UI/Tabs/Orders.lua` (a `select` column and two buttons), `Locales/enUS.lua`
- Test: `tests/queue/queue_spec.lua`, `tests/queue/shopping_retry_spec.lua`, `tests/ui/orders_tab_spec.lua`
- Docs: contract (Queue, OrdersTab), checklist P7-5

**Rules (decided):**
- Multi-select is in the Orders tab only (not on Blizzard's board rows).
- `Queue:GetMissingForEntries(entries) -> { [itemID] = qty }`: the existing `missing_total` over entries that have a
  number `recipeID`, `quantity >= 1` and a `charKey` (others skipped). Each character's own holdings count for that
  character; the warband is taken off once when `queueUseWarband`.
- `Queue:ExportShoppingList(onRetry, opts)`: `opts = nil` is today's export. With `opts.entries`, the missing
  reagents and the tiers come from those entries; the list is named `opts.listName` (default `"FabricationStation"`).
  The retry after item names arrive reuses the same opts.
- Orders tab:
  - first column `{ key = "select", label = "", width = 20 }` with a check button per row; the selection
    `view.selected = { [orderID] = true }` is session-only and dropped for orders no longer listed;
  - a button `L["Shop selected (%d)"]`, disabled with 0 selected; a click builds `ns.UI.OrdersPanel.QueueEntry(view)`
    per selected order (nil entries: recraft or unknown recipe, counted) and calls
    `Queue:ExportShoppingList(retry, { entries = entries, listName = L["FabricationStation Orders"] })`;
  - a button `L["Clear selection"]`;
  - the status line is `ns.UI.QueueTab.ShoppingText(ok, info)`, plus `L["%d orders skipped: recraft or unknown recipe"]`
    when some were skipped.

**Interfaces:**
- Produces: `Queue:GetMissingForEntries(entries)`, `Queue:ExportShoppingList(onRetry, opts)` with
  `opts = { entries?, listName? }`. Task 13 (craft lists) and Task 15 (gather) reuse `GetMissingForEntries`.

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/queue/queue_spec.lua (make_world: recipe 9001 on Main-Realm and Alt-Realm)
it("GetMissingForEntries sums several characters' entries and takes off each one's holdings", function()
  world.counts["Main-Realm"] = { [1001] = 3 }
  local m = Q:GetMissingForEntries({ { recipeID = 9001, quantity = 2, charKey = "Main-Realm" },
    { recipeID = 9001, quantity = 1, charKey = "Alt-Realm" } })
  assert.equals(3 * per_craft(1001) - 3, m[1001])
end)
-- tests/queue/shopping_retry_spec.lua
it("exports given entries under the given list name and leaves the queue's list alone", function()
  local ok = Q:ExportShoppingList(nil, { entries = { entry }, listName = "FabricationStation Orders" })
  assert.is_true(ok); assert.truthy(W.auctionator.lists["FabricationStation Orders"])
  assert.is_nil(W.auctionator.lists["FabricationStation"])
end)
it("retries with the same entries and list name after item names arrive", function() end)
-- tests/ui/orders_tab_spec.lua
it("exports the selected orders' missing reagents", function() end)
it("skips a recraft order in the selection and says how many", function() end)
it("drops selected orders that left the list", function() end)
it("names the count on the button and disables it with nothing selected", function() end)
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** Contract. **P7-5. Shop selected orders.** Tick three orders in the Orders tab (two characters)
  and press Shop selected. Expected: Auctionator has a list "FabricationStation Orders" with each missing reagent once,
  summed; the queue's own "FabricationStation" list is unchanged.
- [ ] **Step 6: Commit** `feat: shop the missing reagents of selected orders`.

---

### Task 5: Ready alerts, new-order flash and board Refresh

**Files:**
- Create: `UI/ReadyAlerts.lua` (module `ReadyAlerts`, toggleable, options group `readyAlerts` 65),
  `tests/helpers/click_only.lua`, `tests/ui/ready_alerts_spec.lua`, `tests/orders/refresh_click_only_spec.lua`
- Modify: `Core/Bus.lua` (`ns.Msg.ORDERS_NEW = "FS_ORDERS_NEW"`), `Modules/Orders.lua` (diff in `OnBoardShown`;
  `RequestBoard`), `UI/OrdersPanel.lua` (Refresh button `v.refresh`, line `v.fresh`), `tests/orders/claim_click_only_spec.lua`
  (requires the helper), `tests/helpers/wow_stubs.lua` (`FlashClientIcon` recording `W.flashes`;
  `C_FunctionContainers.CreateCallback` returning the function; `C_CraftingOrders.RequestCrafterOrders` recording
  `W.orderRequests`), `.luacheckrc` (`FlashClientIcon`, `C_FunctionContainers`), TOC, `Locales/enUS.lua`
- Test: `tests/orders/board_spec.lua`, `tests/ui/orders_panel_spec.lua`
- Docs: contract (Bus, Orders, OrdersPanel, ReadyAlerts), checklist P7-6, P7-7, P7-8

**Rules (decided):**
- **Settings** `ReadyAlerts:Settings()` through `SettingsAccessor("readyAlerts")`, defaults in "Saved data"; every
  alert is off by default. Repair: wrong types get the default; `moxieThreshold` is rounded and clamped to 0..10000
  (0 = off).
- **New orders** (Orders): in `OnBoardShown`, before replacing, `known` = the orderIDs on the current character's board
  and `seenScope = board.scopes[scope] ~= nil`. After scoring, `fresh` = new views whose orderID is not in `known` and
  `not Orders:IsHidden(view)`. When `seenScope` and `fresh > 0`: `SendMessage(ns.Msg.ORDERS_NEW, charKey, fresh,
  typeName)`. The first board of a scope is a baseline (no message).
- **Delivery:** chat line when `chat`; `PlaySound(SOUNDKIT.RAID_WARNING)` (pcall) when `sound`; `OrderAlert:ShowToast(text)`
  when the OrderAlert module is enabled; `FlashClientIcon()` (feature-tested) only for `ORDERS_NEW` with
  `newOrdersFlash` and for `FS_PERSONAL_ORDER_ARRIVED` with `personalOrderFlash`. `newOrdersSound` plays the sound
  for `ORDERS_NEW` even with `sound` off.
- **Texts:** concentration reuses `L["%s %s: concentration is full"]` after the `"FabricationStation: "` prefix key the
  Planner uses; `L["%s %s: Moxie is %d"]`; `L["%s: %s is ready"]` (character, recipe name); `L["%d new order matches
  your filters"]` / `L["%d new orders match your filters"]`.
- **States** (`ReadyAlerts:Check(now)`): concentration full for each `Alts:GetPools(now)` pool with `value >= max`
  (`concentrationFull`); Moxie `>= moxieThreshold` for each character's non-dropped profession record with
  `moxie.value` (threshold > 0); a cooldown ready (`readyAt <= now` or `charges > 0`) for each Scanner cooldown record
  (`cooldownReady`). A key (`"conc:" .. charKey .. ":" .. sl`, `"moxie:..."`, `"cd:" .. charKey .. ":" .. recipeID`)
  alerts when it becomes true; `seen[key]` (session only) is cleared when the state stops. A cooldown that is ready at
  the first check of the session is marked seen without an alert (only a cooldown that becomes ready alerts).
- **Login:** the first `PLAYER_ENTERING_WORLD` (not `isReloadingUi`) schedules `Debounce("readyAlerts.login", 12)`:
  the first `Check` alerts the true concentration and Moxie states (at most 5 lines, then `L["+%d more"]`).
  Concentration is skipped there while the Planner is enabled with `capWarnChat` (it announces those already).
- **Timer:** after each check, `Debounce("readyAlerts.next", delay, Wrap("ReadyAlerts", check))` with `delay` = the
  soonest `fullAt - now` of an enabled not-full pool or `readyAt - now` of an enabled not-ready cooldown, clamped to
  5..21600; none → no timer. `FS_ALTS_CHANGED` and `FS_DATA_CHANGED` reschedule through
  `Debounce("readyAlerts.schedule", 1)`. OnDisable cancels the three keys.
- **Refresh:** `Orders:RequestBoard() -> true | false, "noProfession"|"unavailable"|"busy"`:
  - `"unavailable"` when `C_CraftingOrders.RequestCrafterOrders` or `C_FunctionContainers.CreateCallback` is missing;
  - `"noProfession"` unless `Scanner:IsProfessionOpen()`;
  - `"busy"` while a request is in flight (cleared by its callback or after 10 s, `Debounce("orders.request", 10)`).
  - The request is `{ orderType = <the order type of the last OnBoardShown for the open profession, else 0>,
    searchFavorites = false, initialNonPublicSearch = false, forCrafter = true, offset = 0,
    profession = <current profession>, primarySort = { sortType = 0, reversed = false },
    secondarySort = { sortType = 0, reversed = false }, callback = C_FunctionContainers.CreateCallback(cb) }`.
    **Unverified (P7-7):** before implementing, compare these fields with
    `ProfessionsCrafterOrderPageMixin:RequestOrders` on the `live` branch of Gethe/wow-ui-source and copy any extra
    field it sets.
  - `cb(result, orderType, displayBuckets)`: with `Enum.CraftingOrderResult.Ok` and not `displayBuckets`, runs
    `self:OnBoardShown(orderType, C_CraftingOrders.GetCrafterOrders(), profession)` (Wrap "Orders").
- **Refresh button** (`UI/OrdersPanel.lua`, below Claim Best Order): `L["Refresh"]`, shown only while `RequestBoard`
  is not `"unavailable"`; its `OnClick` calls `O:RequestBoard()` directly; disabled while busy. After an
  `ORDERS_NEW` that a refresh caused, `v.fresh` shows `L["%d new matching orders: press Search on the board to see
  them"]` until the next board show.
- **Structural** (`tests/helpers/click_only.lua`): `tokens(text)`, `references(path, name)`,
  `only_inside(token, path, header)` (every reference to `token` in every Lua file is inside the function whose
  header line matches `header` in `path`), `referenced_only_from_onclick(name, allowedPaths)` (as the claim spec's
  rule: a direct call inside a `SetScript("OnClick", function ... end)` in one of the paths, never a nested closure or
  a value). `claim_click_only_spec.lua` keeps every case and uses the helper.

**Interfaces:**
- Consumes: `Alts:GetPools(now)`, Scanner records, `OrderAlert:ShowToast`, `Orders:IsHidden`.
- Produces: `ns.Msg.ORDERS_NEW`; `Orders:RequestBoard()`; `ReadyAlerts:Settings()`, `ReadyAlerts:Check(now)`,
  `ReadyAlerts.BuildOptions()`; `tests/helpers/click_only.lua` (Tasks 16, 17, 19 use it).

- [ ] **Step 1: Write the failing tests.**
  - `tests/orders/board_spec.lua`: `sends FS_ORDERS_NEW for new matching orders on a scope seen before`,
    `sends nothing for the first board of a scope`, `leaves hidden orders out of the count`.
  - `tests/ui/ready_alerts_spec.lua` (`phase3_env` pools and records; `W.flashes`, `W.printed`):
    `is a toggleable module with every alert off`, `alerts once when a pool becomes full`,
    `alerts again only after the pool dropped below full`, `alerts Moxie at the threshold and not below`,
    `alerts a cooldown that becomes ready but not one ready at login`, `skips concentration at login while the
    Planner announces it`, `flashes the taskbar for new orders only with newOrdersFlash`,
    `flashes for a personal order with personalOrderFlash`, `schedules the next check at the soonest full time,
    clamped to 5..21600 s`, `cancels its debounce keys on disable`, `writes nothing while the saved data is from a
    newer version`.
  - `tests/orders/refresh_click_only_spec.lua`: `references RequestCrafterOrders only inside Orders:RequestBoard`,
    `references RequestBoard only from an OnClick handler in UI/OrdersPanel.lua`.
  - `tests/ui/orders_panel_spec.lua`: `hides Refresh without C_FunctionContainers`, `a Refresh click sends one
    request and the callback scores the board`, `is busy until the callback or 10 s`, `shows the new-orders line after
    a refresh found new orders`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the helper extraction first (claim spec green on its own), then Orders, ReadyAlerts and
  the panel.
- [ ] **Step 4: Run** focused, full suite, luacheck, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** Contract entries. **P7-6. Taskbar flash.** Turn on "Flash the taskbar on new orders", alt-tab
  out with the order board open on the public tab, have a new public order appear (press Refresh or Search).
  Expected: the WoW icon flashes; `/run print(type(FlashClientIcon))` prints `function`. **P7-7. Board Refresh.**
  Press Refresh on the public tab. Expected: no error; when there are new orders the side panel says so; Blizzard's
  list still works (Search, scrolling, Start) and shows them after Search. Report any field Blizzard's
  `RequestOrders` sends that the plan lacked. **P7-8. Ready alerts.** Turn on concentration, Moxie (threshold just
  above your amount) and cooldown alerts. Expected: one chat line (and a toast with OrderAlert on) when concentration
  fills during play, when Moxie reaches the threshold, and when a cooldown comes off; none repeat until the state
  resets.
- [ ] **Step 6: Commit** `feat: ready alerts, taskbar flash on new orders and a board Refresh button`.

---
## Sales, stock and the craft log (Tasks 6–10)

### Task 6: Mail and auction-house tracking (data)

**Files:**
- Create: `Modules/SaleLog.lua` (module `SaleLog`, toggleable), `tests/salelog/salelog_spec.lua`,
  `tests/modules/scanner_mail_spec.lua`
- Modify: `Modules/Scanner.lua` (`mailOpen`, mail events, `ScanMail`, `GetMailCount`), `Modules/Recipes.lua`
  (`on_data_changed`: `"mail"` bumps nothing), `Core/Bus.lua` (`SALELOG_CHANGED = "FS_SALELOG_CHANGED"`),
  `tests/helpers/wow_stubs.lua` (inert `C_AuctionHouse` with `GetNumOwnedAuctions` → 0, `GetOwnedAuctionInfo` → nil,
  `PostItem`/`PostCommodity`/`CancelAuction` no-ops; `GetInboxNumItems` → 0, `GetInboxItem` → nil;
  `Enum.AuctionStatus = { Active = 0, Sold = 1 }`), `tests/helpers/wow_stubs_spec.lua`, `.luacheckrc`
  (`C_AuctionHouse`, `GetInboxNumItems`, `GetInboxItem`, `AUCTION_EXPIRED_MAIL_SUBJECT`, `ATTACHMENTS_MAX_RECEIVE`),
  TOC
- Docs: contract (Scanner, Bus, SaleLog), checklist P7-9 to P7-13

**Rules (decided):**
- **Mail snapshot** (Scanner, current character):
  - `MAIL_SHOW` sets `self.mailOpen = true`, `MAIL_CLOSED` false; `MAIL_INBOX_UPDATE` →
    `Debounce("scanner.mail", 0.5, Wrap("Scanner", ScanMail))`.
  - `Scanner:ScanMail()`: returns false unless enabled, writable and `mailOpen`. For `i = 1, GetInboxNumItems()`:
    `local _, _, _, _, _, cod, _, hasItem = GetInboxHeaderInfo(i)`; mail with `cod > 0` is skipped; with `hasItem`,
    `for j = 1, ATTACHMENTS_MAX_RECEIVE or 12` sums `select(4, GetInboxItem(i, j))` under `select(2, ...)` (the itemID;
    unverified, P7-9). Writes `characters[me].mail = { time = Now(), items }`; sends `FS_DATA_CHANGED(me, "mail")`
    only when a count changed.
  - `Scanner:GetMailCount(itemID, charKey|nil) -> count, ageSeconds|nil`: one character (nil = every character
    summed); `count` sums the known snapshots (0 when known and none); `ageSeconds` = now minus the oldest snapshot
    `time` that holds the item, nil when none does.
- **SaleLog** (event sources as in "Decisions"): every handler `Wrap("SaleLog", ...)`; hooks once per session
  (`hooksecurefunc(C_AuctionHouse, name, body)` when the target is a function, else logged once as
  `"<name> not found in this client; that action is not recorded"`); bodies return while SaleLog is off.
  - Pending posts: FIFO, at most 20, each `{ itemID, quantity, unitPrice, at }`; `PostItem(item, _, quantity, _, buyout)`
    gives `unitPrice = floor(buyout / quantity)` when `buyout` is a number; `PostCommodity(item, _, quantity,
    unitPrice)`. `itemID = pcall(C_Item.GetItemID, item)`; a post without an itemID is not queued.
  - `AUCTION_HOUSE_AUCTION_CREATED`: the oldest pending post at most 60 s old becomes a `"post"` event and is added to
    `listings[me].items`; older ones are dropped.
  - `OWNED_AUCTIONS_UPDATED`: `listings[me] = { time = Now(), items }` from the owned auctions with
    `status == Enum.AuctionStatus.Active` (`itemKey.itemID`, `quantity`); `ownedByID[auctionID] = { itemID, quantity }`
    for the session.
  - `CancelAuction(ownedAuctionID)` remembers `ownedByID[ownedAuctionID]`; `AUCTION_CANCELED(auctionID)` turns it into
    a `"cancel"` event and lowers the listing (never below 0).
  - `MAIL_INBOX_UPDATE` → `Debounce("saleLog.mail", 0.5)`: expiry scan (pattern built from
    `AUCTION_EXPIRED_MAIL_SUBJECT` as the Ledger builds its sold pattern; English fallback `"Auction expired: %s"`),
    signature rule from "Decisions"; an `"expire"` event also lowers the listing.
  - Events capped at 2000 (`ns.Util.PushCapped`); at enable, events older than 365 days and `seenMail` signatures
    older than 31 days are pruned.
  - `SaleLog:Settings()` (`SettingsAccessor("saleLog")`; `windowDays` rounded and clamped to 7..365; `tooltip`
    boolean).
  - `SaleLog:GetListedCount(itemID, charKey|nil) -> qty, ageSeconds|nil` (nil, nil when no character has a listing
    snapshot).
  - `SaleLog:GetItemStats(itemID, now) -> ItemSaleStats`, `SaleLog:GetAllStats(now) -> { [itemID] = ItemSaleStats }`
    (items with an event or a sale in the window):
    `ItemSaleStats = { posted, sold|nil, expired, cancelled, saleRate|nil, lastSale = { time, unitPrice } | nil,
    listed|nil, listedAge|nil }`. Counts are quantities within `windowDays`. `sold` and `lastSale` come from
    `Ledger:Query({ type = "sale", since = now - windowDays * 86400 })` entries with that itemID (`unitPrice =
    floor(amount / quantity)`, after the AH cut); nil while the Ledger is missing or off. `saleRate = sold / (sold +
    expired + cancelled)` when `sold` is a number and the sum is above 0, else nil.
  - Every write sends `FS_SALELOG_CHANGED`. Nothing is written while `dbIsNewer`.

**Interfaces:**
- Produces: `Scanner:ScanMail()`, `Scanner:GetMailCount(itemID, charKey)`, kind `"mail"`; module `SaleLog` with
  `Settings`, `GetListedCount`, `GetItemStats`, `GetAllStats`; `ns.Msg.SALELOG_CHANGED`. Task 7 reads the two counts;
  Task 8 the stats; Task 15 the mail counts.

- [ ] **Step 1: Write the failing tests.**
  - `tests/modules/scanner_mail_spec.lua`: `snapshots the attachments of non-COD mail while the mailbox is open`,
    `does not scan while the mailbox is closed`, `sends "mail" only when a count changed`,
    `GetMailCount sums characters and reports the oldest age`, `Recipes ignore the "mail" kind`
    (`Recipes:GetDataStamp(me)` unchanged), `writes nothing while the saved data is from a newer version`.
  - `tests/salelog/salelog_spec.lua` (`P2.boot`, fake `Ledger` with `Query`):
    `records a post when the auction is created`, `drops a pending post older than 60 s`,
    `replaces the listing from the owned auctions, active ones only`, `records a cancel and lowers the listing`,
    `records an expiry from mail once across sessions` (two scans, a `W.logout()` and a new boot → one event),
    `ignores cancelled-auction mail`, `computes the sale rate from the Ledger's sales and its own outcomes`
    (sold 6, expired 3, cancelled 1 → `0.6`), `reports an unknown sale rate without outcomes`,
    `leaves sold unknown while the Ledger is off`, `logs a missing hook target once and keeps working`,
    `prunes old events and signatures at enable`, `cancels saleLog.mail on disable`,
    `writes nothing while the saved data is from a newer version`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** Scanner's mail part, then SaleLog.
- [ ] **Step 4: Run** focused, full suite, luacheck. Expected: PASS.
- [ ] **Step 5: Docs.** Contract. **P7-9. Mail attachments.** Open a mailbox with an item mail and a COD mail:
  `/dump FabricationStationDB.global.characters["<you>"].mail` after `/reload` lists the item mail's items and not
  the COD one; `/dump GetInboxItem(1, 1)` shows the itemID second. **P7-10. Own listings.** Open the AH Auctions tab.
  Expected: `.auctionLog.listings["<you>"]` holds your active auctions; sold ones waiting for pickup are left out.
  **P7-11. Posts.** Post one item and one commodity stack. Expected: two `"post"` events with the right itemIDs and
  quantities. **P7-12. Cancels.** Cancel one auction. Expected: one `"cancel"` event; the listing drops by its
  quantity. **P7-13. Expiries.** With an expired-auction mail in the box, open the mailbox twice and `/reload`.
  Expected: one `"expire"` event; report the subject text if none appears (non-English clients:
  `/dump AUCTION_EXPIRED_MAIL_SUBJECT`).
- [ ] **Step 6: Commit** `feat: track own auctions, posts, cancels, expiries and mail contents`.

---

### Task 7: Restock gates and outside stock

**Files:**
- Modify: `Modules/Queue.lua` (`restock_entry`, `SetRestock`, new `SetRestockMinProfit`, `GetRestockMinProfit`,
  `GetRestockStatus`), `Modules/Recipes.lua` (`DEFAULTS.restockCountMail = true`, `restockCountListed = true`; two
  toggles in `build_options`), `UI/Tabs/Queue.lua` (restock editor and rows), `Locales/enUS.lua`
- Test: `tests/queue/queue_spec.lua`, `tests/ui/queue_tab_spec.lua`
- Docs: contract (Queue, Recipes DEFAULTS), checklist P7-14

**Rules (decided):**
- **Held** for a restock target = `Scanner:GetItemCount(itemID, nil).total`, plus `Scanner:GetMailCount(itemID, nil)`
  while `restockCountMail`, plus `SaleLog:GetListedCount(itemID, nil)` (nil counts 0) while `restockCountListed` and
  SaleLog is enabled.
- **Gate:** `queue.restockMinProfit[itemID]` (a number ≥ 0, copper per craft). With a gate, the chosen crafter's
  `profit` must be a number `>= minProfit`; a nil profit makes no entry (`"unknownProfit"`), a lower one none
  (`"belowMinProfit"`). The crafter choice is unchanged (best profit, unreachable targets skipped).
- `Queue:SetRestockMinProfit(itemID, copper|nil)`: floors; a negative or non-number other than nil is ignored; nil
  removes. `SetRestock(itemID, nil)` also removes the min profit. `Queue:GetRestockMinProfit(itemID) -> copper|nil`.
- `Queue:GetRestockStatus(itemID) -> RestockStatus|nil` (nil without a target):
  `RestockStatus = { itemID, target, held = { owned, mail, listed, total }, minProfit, profit, crafter, crafts,
  status }` with `status` one of `"queued"`, `"stocked"`, `"belowMinProfit"`, `"unknownProfit"`, `"noRecipe"`,
  `"noCrafter"`. It decides exactly as `restock_entry` does (one shared local).
- **Queue tab:** the restock editor gets a third box, `L["Min profit (gold)"]` (`ns.UI.ParseMoney`; empty = none). A
  target row shows `L["Target %d · held %d"]`, or `L["Target %d · held %d (mail %d, listed %d)"]` when mail or listed
  is above 0, and a status cell: `L["%d crafts queued"]`/`L["%d craft queued"]`, `L["Stocked"]`,
  `L["Below min profit (%s per craft)"]`, `L["Profit unknown: not restocked"]`, `L["No recipe makes this item"]`,
  `L["No crafter reaches this quality"]`.

**Interfaces:**
- Consumes: `Scanner:GetMailCount`, `SaleLog:GetListedCount` (Task 6).
- Produces: `Queue:SetRestockMinProfit`, `GetRestockMinProfit`, `GetRestockStatus`; `queue.restockMinProfit`.

- [ ] **Step 1: Write the failing tests** (`make_world`, a fake SaleLog): `gates a restock entry below the min profit`,
  `makes no entry when the profit is unknown and a gate is set`, `counts mail and own listings as held`,
  `leaves mail out with restockCountMail off`, `leaves listings out while SaleLog is off`,
  `GetRestockStatus explains each case` (one assertion per status), `SetRestock nil clears the min profit`,
  `writes nothing while the saved data is from a newer version` (SetRestockMinProfit);
  `tests/ui/queue_tab_spec.lua`: `sets a min profit from the editor`, `shows held with mail and listed`,
  `shows why a target is not restocked`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** Contract. **P7-14. Restock with listings.** Set a restock target of 10 for an item you have 4
  of, with 5 on the AH (open the Auctions tab once). Expected: 1 craft's worth is queued, and the row says
  "held 9 (mail 0, listed 5)". Set Min profit above the item's profit: the entry goes and the row says "Below min
  profit".
- [ ] **Step 6: Commit** `feat: restock gates (min profit) and own listings and mail counted as held`.

---

### Task 8: Sale log view and item tooltips

**Files:**
- Create: `UI/FeatureLines.lua` (core registrar module `FeatureLines`), `tests/salelog/tooltip_spec.lua`
- Modify: `Modules/SaleLog.lua` (`TooltipLines`), `UI/Tabs/Ledger.lua` (section row, Auctions section),
  `UI/OrdersOptions.lua` (the two `saleLog` settings), TOC, `Locales/enUS.lua`
- Test: `tests/ui/ledger_tab_spec.lua`, `tests/ui/orders_options_spec.lua`
- Docs: contract (LedgerTab, Tooltips providers), checklist P7-15

**Rules (decided):**
- **Ledger tab sections:** a row of section buttons above the page, `Tab.SECTIONS = { { id = "profit", label =
  L["Profit"] }, { id = "auctions", label = L["Auctions"] } }` (Task 10 adds `crafts`); the shown one
  `LockHighlight`ed; the choice is session-only (default `profit`, which is today's page unchanged).
- **Auctions section:** `Tab.AuctionRows(stats, now) -> rows`, one per item of `SaleLog:GetAllStats(now)`, sorted by
  `sold` desc (nil last), then item name, then itemID. Columns: Item (flexible, icon), Posted, Sold, Expired,
  Cancelled, Rate (`L["%d%%"]` floored, `"?"` when nil), Last sale (`OrdersPanel.CompactMoney`, `"—"` without one),
  Listed (`"?"` when nil). Hide order when narrow: Cancelled, Expired, Posted. Footer
  `L["Your own auctions over the last %d days. Sales come from the Ledger's sold mail; prices are after the AH cut."]`.
  SaleLog off → `L["Sale log off: nothing new is recorded"]`; Ledger off → the Rate cells are `"?"` and the row
  tooltip says `L["Sales unknown: the Ledger is off"]`.
- **Tooltip** (`SaleLog:TooltipLines(itemID, now)`, provider `"saleLog"` registered by `FeatureLines` in
  `OnInitialize` with `Tooltips:RegisterLineProvider`; `{}` while SaleLog is off or `tooltip` is false):
  `{ L["Your sales"], L["%d of %d sold (%d%%)"] }` when the outcomes sum above 0 and `sold` is known;
  `{ L["Last sale"], L["%s each, %s ago"] }` (`FormatMoney`, `FormatAge`); `{ L["Listed now"], tostring(listed) }`
  when above 0. Nothing for an item without history.
- **Options** (`orders` group, a `L["Sale log"]` header): `L["Sale history window (days)"]` 7..365 and
  `L["Show your sales in item tooltips"]`.

**Interfaces:**
- Consumes: `SaleLog:GetAllStats`, `GetItemStats` (Task 6).
- Produces: `FeatureLines` (Tasks 12 and 14 add their providers to it); `ns.UI.LedgerTab.SECTIONS`, `AuctionRows`;
  `SaleLog:TooltipLines(itemID, now)`.

- [ ] **Step 1: Write the failing tests:** `switches between Profit and Auctions` (the Profit page is today's rows),
  `lists each item's posts, sales, expiries, cancels and rate`, `shows ? for an unknown rate and names why`,
  `says the sale log is off`, `hides Cancelled, then Expired, then Posted when narrow`;
  tooltip: `adds the sale lines to an item with history`, `adds nothing without history or with the setting off`,
  `returns nothing while SaleLog is off`; options: `clamps the window to 7..365 days`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** Contract. **P7-15. Sales in tooltips and the Ledger.** After selling and having one auction
  expire, hover the item. Expected: "Your sales: 1 of 2 sold (50%)", "Last sale: <price> each, <age> ago"; the Ledger
  tab's Auctions section has the same numbers.
- [ ] **Step 6: Commit** `feat: sale log view in the Ledger and sale lines in item tooltips`.

---

### Task 9: Craft log capture

**Files:**
- Create: `Modules/CraftLog.lua` (module `CraftLog`, toggleable), `tests/craftlog/capture_spec.lua`
- Modify: `Core/Bus.lua` (`CRAFTLOG_CHANGED = "FS_CRAFTLOG_CHANGED"`), `tests/queue/craft_spec.lua` (the structural
  cases at 475-611), TOC
- Docs: contract (CraftLog, Bus, the click-only rule), checklist P7-16, P7-17

**Rules (decided):**
- **Hook:** `Modules/CraftLog.lua` has the same three lines as the Ledger: `local function hook(tbl, name, fn)`, its
  guard line, `hooksecurefunc(tbl, name, body(fn))`, and exactly one
  `hook(C_TradeSkillUI, "CraftRecipe", function(...) self:OnCraftRecipe(...) end)`, installed once per session; the
  body returns while CraftLog is off. `craft_spec.lua`: the post-hook and helper cases run for both files (one line
  each); "calls CraftRecipe only inside Queue:CraftNext" exempts the post-hook line in both.
- **`CraftLog:OnCraftRecipe(recipeID, numCasts, craftingReagents, _, orderID, applyConcentration)`** sets
  `pending = { recipeID, castsLeft = max(1, floor(numCasts or 1)), orderID, applyConcentration = (applyConcentration
  == true), at = Now(), reagents = DeepCopy(craftingReagents), calib = DeepCopy(Recipes:GetCalibration(me, recipeID)),
  predicted, game }`, each step pcall'd:
  - `allocation, optionalItemIDs = Recipes:FromCraftingReagentInfo(recipeID, craftingReagents)`;
  - `predicted` from `Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration)`: `quality =
    expectedQuality`, `qualityChances` (copy), `yield = expectedYield`, `concentrationCost =
    concentrationCostForAllocation` (only with concentration), `multicraftValue`, `resourcefulnessValue`;
  - `game` from `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration, optionalItemIDs)`: `quality =
    craftingQuality`, and the number fields `concentrationCost, baseSkill, bonusSkill, baseDifficulty,
    bonusDifficulty, lowerSkillThreshold, upperSkillTreshold`.
- **`CraftLog:OnCraftResult(data)`** (`TRADE_SKILL_ITEM_CRAFTED_RESULT`):
  - ignored when `data` is not a table or `data.isEnchant`;
  - `opID = data.operationID` (0 = nil). With `opID == last.operationID`: an extra. It adds `data.quantity` to
    `actual.quantity`, and to `actual.multicraft` unless the first result carried a number `data.multicraft`. It
    merges `resourcesReturned`.
  - else the pending craft, when it is at most 60 s old and `data.itemID` is one of its schematic's `outputItemIDs`
    (else the result is not logged): `castsLeft - 1` (0 ends it), a new entry with the recipe from the hook
    (`pending.recipeID`, never the panel's selection);
  - `actual = { quality = data.craftingQuality, quantity = data.quantity, baseQuantity = schematic.quantityMin when
    it equals quantityMax, multicraft = number data.multicraft or 0, resourcesReturned = { [itemID] = qty } (from the
    list of `{ reagent = { itemID }, quantity }`), concentrationSpent = number data.concentrationSpent,
    ingenuityRefund = number data.ingenuityRefund, ingenuityProc = boolean data.hasIngenuityProc }`. Unverified
    (P7-16): the four fields after `resourcesReturned`; a missing one stays nil.
  - `fixture = { reagents = pending.reagents, calib = pending.calib, build = select(2, GetBuildInfo()) }`.
  - Push (cap 1000); then every entry beyond the newest 100 loses its `fixture`. Sends `FS_CRAFTLOG_CHANGED`.
- `UNIT_SPELLCAST_INTERRUPTED("player", _, spellID)` with `spellID` nil or the pending recipe drops `pending`.
- Recrafts, enchants and salvage are not logged (no hook; an enchant result is ignored; a recraft result finds no
  pending craft whose output it is).
- `CraftLog:GetEntries(filter) -> { CraftLogEntry }` newest first (`filter = { since?, charKey?, recipeID? }`; the
  stored rows, read-only).

**Interfaces:**
- Consumes: `Recipes:FromCraftingReagentInfo`, `Recipes:PredictLive`, `Recipes:GetCalibration`,
  `Scanner:GetLiveOperationInfo`, `Scanner:GetSchematic`.
- Produces: `CraftLog:GetEntries`, `db.global.craftLog`, `ns.Msg.CRAFTLOG_CHANGED`. Task 10 summarizes and exports.

- [ ] **Step 1: Write the failing tests** (`make_world` with `world.live` operation infos):

```lua
it("logs a craft with FabricationStation's and the game's prediction", function()
  craft(9001, reagents, false); result({ itemID = 5002, quantity = 1, craftingQuality = 2, operationID = 11 })
  local e = CL:GetEntries()[1]
  assert.equals(9001, e.recipeID); assert.equals(2, e.actual.quality)
  assert.equals(world.live[9001].craftingQuality, e.game.quality); assert.is_number(e.predicted.quality)
end)
it("logs a craft from Blizzard's button under the crafted recipe", function()
  -- the panel shows 9001; Blizzard's button crafts 9002 (its CraftRecipe hook runs) -> the entry is 9002
end)
it("adds a Multicraft extra to the craft with the same operationID only", function()
  craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
  result({ itemID = 5002, quantity = 2, operationID = 11 })
  craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 12 })
  local list = CL:GetEntries()
  assert.equals(0, list[1].actual.multicraft); assert.equals(2, list[2].actual.multicraft)
end)
```
  and: `uses the multicraft field when the game gives it, without counting the extras twice`,
  `records resourcefulness returns, concentration spent and the ingenuity refund when present`,
  `leaves an actual value nil when the game omits it`, `ignores enchants and results that are not the pending
  recipe's output`, `drops the pending craft on an interrupt and after 60 s`, `counts down a multi-cast craft`,
  `keeps the fixture on the newest 100 entries only`, `caps the log at 1000 entries`,
  `writes nothing while the saved data is from a newer version`; in `craft_spec.lua`:
  `allows exactly one CraftRecipe post-hook line in each of Ledger and CraftLog`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** CraftLog and widen the structural cases.
- [ ] **Step 4: Run** focused, full suite, luacheck. Expected: PASS.
- [ ] **Step 5: Docs.** Contract. **P7-16. Craft result fields.** Craft one quality recipe with concentration, then
  `/dump` the last entry of `FabricationStationDB.global.craftLog.entries` after `/reload`. Expected: `actual.quality`
  matches the item; report whether `concentrationSpent`, `ingenuityRefund`, `ingenuityProc` and a `multicraft` number
  are present. **P7-17. Multicraft extras.** Craft until a Multicraft proc. Expected: one entry with
  `actual.multicraft` equal to the extra items, not a second entry.
- [ ] **Step 6: Commit** `feat: craft log of actual results next to the predictions`.

---

### Task 10: Craft log view and golden-fixture export

**Files:**
- Create: `tools/export_math_fixtures.lua`, `tests/tools/export_math_fixtures_spec.lua`, `tests/math/golden_spec.lua`,
  `tests/fixtures/math/index.lua` (`return {}`), `tests/craftlog/summary_spec.lua`
- Modify: `Modules/CraftLog.lua` (`Summary`), `UI/Tabs/Ledger.lua` (Crafts section), `Locales/enUS.lua`
- Test: `tests/ui/ledger_tab_spec.lua`
- Docs: contract (Diagnostics tools line, CraftLog), checklist P7-18, `docs/RELEASE_CHECKLIST.md` (the patch-day step
  "capture fixtures, export, run golden_spec": phase 6 Appendix A #8)

**Rules (decided):**
- `CraftLog:Summary(filter) -> { [recipeID] = RecipeCraftStats }` over `GetEntries(filter)`:
  `RecipeCraftStats = { crafts, qualityKnown, asPredicted, above, below, gameAgreed, expectedExtra, actualExtra,
  multicraftProcs, resourcefulnessProcs, concentrationSpent|nil, concentrationPredicted|nil }`.
  - `qualityKnown`: entries with both `actual.quality` and `predicted.quality`; `asPredicted`/`above`/`below` split
    them; `gameAgreed`: entries whose `game.quality == actual.quality`.
  - `expectedExtra = Σ (predicted.yield - (actual.baseQuantity or predicted.yield))`; `actualExtra = Σ
    actual.multicraft`.
  - The concentration sums count only entries with both numbers; nil when there are none.
- **Crafts section** (`Tab.CraftRows(summary, names)`): Recipe (flexible), Crafts, Quality (`L["%d of %d as
  predicted"]`), Multicraft (`L["+%d (expected +%s)"]`, expected with one decimal), Resourcefulness (`L["%d procs"]` /
  `L["%d proc"]`), Concentration (`L["%s of %s predicted"]`, `"—"` when nil). Sorted by crafts desc, then name. Hide
  order: Concentration, Resourcefulness. Footer `L["Your crafts over the last %d weeks, next to the predictions."]`
  (the tab's `WEEKS`).
- **Exporter** `lua tools/export_math_fixtures.lua [--force] <SavedVariables> [outDir=tests/fixtures/math]`:
  - runs the SavedVariables file in an empty environment (as `tools/export_captures.lua`), and the committed
    `Data/GameData*.lua` files against a minimal collector `ns = { GameData = { Define = fn(name, build, tbl) } }`;
  - capture fixtures: every `captures.list` capture with a `recipeCalib[charKey][recipeID]` →
    `capture_<recipeID>_<id>.lua` = `{ source = "capture", recipeID, schematic, calib, reagents, operationInfo,
    applyConcentration, gameData }`;
  - craft fixtures: every `craftLog.entries` entry with `fixture`, `game` and `schematics[recipeID]` →
    `craft_<recipeID>_<id>.lua` = `{ source = "craft", recipeID, schematic, calib = fixture.calib, reagents =
    fixture.reagents, operationInfo = { craftingQuality = game.quality, concentrationCost = game.concentrationCost,
    baseSkill, bonusSkill, baseDifficulty, bonusDifficulty, lowerSkillThreshold, upperSkillTreshold }, actualQuality =
    actual.quality, applyConcentration, gameData }`;
  - `gameData` holds only the recipe's rows: `ReagentQuality`, `ReagentCategories` and `OptionalReagents` of its
    reagents, and its `CraftingData`, `ItemCraftingData`, `QualityThresholds`, `ConcentrationCurves` rows;
  - output through `tools/lib/serialize.lua` (sorted keys); an existing file with identical content is fine, a
    different one stops the export unless `--force`; nothing is written unless every fixture passes;
  - `index.lua` = the sorted union of the existing names and the new ones;
  - prints `exported N fixtures (M captures skipped: no calibration, K crafts skipped: no schematic)`.
- **`tests/math/golden_spec.lua`**: phase 1b Task 9's spec (pending while the index is empty), plus for `source ==
  "craft"`: `assert.equals(f.operationInfo.craftingQuality, r.expectedQuality)` and
  `assert.equals(f.operationInfo.craftingQuality, f.actualQuality)` (the game's prediction against what it made;
  P7-18 reports a mismatch rather than loosening the assertion).

**Interfaces:**
- Consumes: `CraftLog:GetEntries` (Task 9), 1a's capture record, `tools/lib/serialize.lua`.
- Produces: `CraftLog:Summary(filter)`, the exporter, the golden spec. Closes phase 6 Appendix A #1 together with
  `/fs capture` once P7-18 brings real fixtures.

- [ ] **Step 1: Write the failing tests:** summary: `splits quality as predicted, above and below`, `sums expected and
  actual Multicraft extras`, `leaves the concentration sums nil without data`; ledger tab: `lists each recipe's
  results in the Crafts section`; exporter (temp SavedVariables with one calibrated capture, one uncalibrated, one
  craft entry with a schematic and one without): `exports a capture and a craft fixture and indexes both`,
  `prints the skipped counts`, `keeps only the recipe's GameData rows`, `refuses to overwrite a different fixture
  without --force`, `writes deterministic output`. The golden spec is pending with the empty index.
- [ ] **Step 2: Run.** Expected: FAIL (exporter missing; golden spec errors on the missing index).
- [ ] **Step 3: Implement** the summary, the section, the exporter and `index.lua`.
- [ ] **Step 4: Run** focused, full suite. Expected: PASS; golden spec 1 pending.
- [ ] **Step 5: Docs.** **P7-18. Golden fixtures from crafts.** Craft 8 recipes (the phase 1b Task 9 list: rank 1, rank
  2, just under and over a threshold, a difficulty optional, a skill finishing reagent, an ingenuity effect, a
  5-quality recipe), `/reload`, then
  `lua tools/export_math_fixtures.lua "<WoW>/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua"`
  and `busted tests/math/golden_spec.lua`. Expected: ≥ 8 fixtures; report every failing assertion (phase 1b Task 9
  Step 5 says which constant each one pins).
- [ ] **Step 6: Commit** `feat: craft results view and golden-fixture export from crafts and captures`.

---
## Better crafting choices (Tasks 11–15)

### Task 11: Optional and finishing reagent optimizer (Math and Recipes)

**Files:**
- Create: `Math/Optionals.lua` (`ns.Math.Optionals`, pure), `tests/math/optionals_spec.lua`
- Modify: `Modules/CraftingData.lua` (`BuildInput`: `input.optionalSlots`), `Modules/Recipes.lua` (`full_opts`,
  `evaluate`, `optionalAllocation`, `BestOptionals`, `DEFAULTS.optionalMode`, one select in `build_options`), TOC,
  `Locales/enUS.lua`
- Test: `tests/crafting/build_input_spec.lua`, `tests/recipes/evaluate_spec.lua`
- Docs: contract (Math, CraftingData, Recipes), checklist P7-19

**Rules (decided):**
- **`BuildInput`** with `args.optionalItemIDs` (a list) also returns `input.optionalSlots = { { slotIndex, kind,
  quantity, itemIDs = { itemID... } } }`: every optional or finishing slot that is not `IsAllocated`, has reagents,
  in schematic order. Without `optionalItemIDs`, no `optionalSlots`.
- **`Optionals.Best(input, opts) -> OptionalsResult`**, `opts = { mode = "simple"|"permutation", maxCombinations = 64 }`:
  - Candidates per slot: its items whose `input.optionals` entry has a number `price` and a stats table with at least
    one non-zero value. The others are counted once per itemID in `skipped.unknownPrice` / `skipped.noEffect`.
  - `evaluate(picked)` = `Profit.EvaluateCraft` on a shallow copy of `input` whose `optionals` are the picked entries.
    `base = evaluate({})`.
  - Better: a number profit beats nil; a higher profit wins; on equal profit fewer items win, then the smaller sorted
    itemID list.
  - `"permutation"` when `Π (1 + #candidates) <= maxCombinations`: every combination (at most one item per slot);
    otherwise it runs `"simple"` and reports `mode = "simple"`.
  - `"simple"`: slots in order; for each, the best of "the current pick plus one candidate" replaces the current pick
    when it is better.
  - A base with a nil profit returns `{ itemIDs = {}, result = base, base = base, ... }` (nothing can be ranked).
  - `OptionalsResult = { itemIDs (sorted), result = MathResult, base = MathResult, mode, evaluated, skipped = {
    unknownPrice, noEffect } }`.
- **Recipes:**
  - `full_opts` keeps a sixth key, `optionalItemIDs`: the sorted number IDs, nil when absent or empty (so plain calls
    share their cache entry). The cache key includes it.
  - `evaluate` with `o.optionalItemIDs`: `build(..., o.optionalItemIDs, ...)`, then `input.optionals` keeps only those
    IDs; a requested ID the schematic does not list is added as `{ itemID, price = nil, stats = {} }` (the result is
    unpriced and `flags.unknownOptional = true`; never priced as free).
  - `RecipeResult.optionalAllocation = { { slotIndex, itemID, quantity } }` for those IDs (the first optional slot
    listing the item; the slot's quantity); `{}` for a plain call.
  - `Recipes.DEFAULTS.optionalMode = "simple"`; the crafting options get a select `L["Optional reagents"]`: `off`
    `L["Off"]`, `simple` `L["One slot at a time"]`, `permutation` `L["Every combination (up to 64)"]`.
  - `Recipes:BestOptionals(recipeID, charKey, opts) -> { itemIDs, result = RecipeResult, base = RecipeResult, gain =
    copper|nil, mode, skipped } | nil`: nil with `optionalMode == "off"`, no schematic, or no optional slot. It
    builds the input once with `optionalItemIDs = {}`, runs `Optionals.Best`, then `result = Evaluate(recipeID,
    charKey, opts + { optionalItemIDs = itemIDs })` and `base = Evaluate(recipeID, charKey, opts)`; `gain =
    result.profit - base.profit` when both are numbers. Memoised per recipe, character, full opts and mode while
    `Prices:GetVersion()` and `GetDataStamp(charKey)` are unchanged. On demand only (the panel, a list, a click);
    the recipe scan still ranks plain results.

**Interfaces:**
- Produces: `ns.Math.Optionals.Best`; `input.optionalSlots`; `opts.optionalItemIDs`; `RecipeResult.optionalAllocation`;
  `Recipes:BestOptionals`. Task 12 queues and crafts with them; Task 13 uses them for lists.

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/math/optionals_spec.lua (a hand-built RecipeInput: one optional slot, items 701 (+skill to reach Q2, 10g)
-- and 702 (+multicraft, 50g); a second slot with 703 (no price); a third with 704 (stats {}))
it("picks the optional that raises profit most", function()
  local r = Optionals.Best(input, { mode = "simple" })
  assert.same({ 701 }, r.itemIDs); assert.is_true(r.result.profit > r.base.profit)
end)
it("never picks an optional without a price and counts it", function()
  assert.equals(1, Optionals.Best(input, { mode = "simple" }).skipped.unknownPrice)
end)
it("skips an optional whose effects are not modelled and counts it", function() end)
it("picks nothing when no optional beats none", function() end)
it("tries every combination when there are 64 or fewer", function() end)
it("falls back to one slot at a time above 64 combinations", function()
  assert.equals("simple", Optionals.Best(wide_input, { mode = "permutation" }).mode)
end)
it("keeps the fewer optionals on a tie", function() end)
it("returns the base when the output price is unknown", function() end)
```
  `build_input_spec.lua`: `lists the optional slots with their items`. `evaluate_spec.lua`: `evaluates only the
  requested optionals and caches by their sorted IDs`, `shares the plain cache entry for an empty list`, `marks an
  unknown requested optional unpriced`, `fills optionalAllocation with the slot quantity`, `BestOptionals returns the
  pick and the gain`, `BestOptionals is nil with optionalMode off`, `BestOptionals memoises until the price version
  changes`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `Math/Optionals.lua` (no WoW globals; luacheck's `Math/` rule applies), then
  CraftingData and Recipes.
- [ ] **Step 4: Run** focused, full suite, luacheck. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-19. Optionals against the game.** Pick a recipe with a skill-raising finishing reagent
  and a Multicraft optional. Expected: the side panel's "Best optionals" (Task 12) matches what the game shows when you
  put that reagent in (predicted quality in Blizzard's window); report the recipe when the predicted quality differs.
- [ ] **Step 6: Commit** `feat: optional and finishing reagent optimizer`.

---

### Task 12: Optionals in the side panel, the queue and Craft Next

**Files:**
- Modify: `Modules/Queue.lua` (`Add`, `copy_entry`, `CraftEvaluateOpts`, `per_craft`), `Modules/QueueCraft.lua`
  (`one_craft` / `CraftNext` reagents and the have check), `Modules/Scanner.lua` (new `OptionalReagentInfos`, used by
  `GetLiveOperationInfo`), `UI/FeatureLines.lua` (panel provider `"optionals"`, action `"queueOptionals"`),
  `UI/Tabs/Queue.lua` (second line), `Locales/enUS.lua`
- Test: `tests/queue/queue_spec.lua`, `tests/queue/craft_spec.lua`, `tests/modules/scanner_professions_spec.lua`,
  `tests/ui/feature_lines_spec.lua` (new), `tests/ui/queue_tab_spec.lua`
- Docs: contract (Queue, Scanner, FeatureLines), checklist P7-20

**Rules (decided):**
- `Queue:Add(entry)` accepts `optionalItemIDs`: number IDs, deduplicated, sorted, at most 8; stored only when
  non-empty. `copy_entry` copies the list. `CraftEvaluateOpts(entry)` passes it.
- `per_craft` adds `result.optionalAllocation` quantities to the need, so missing reagents and the shopping list
  include optionals.
- `Scanner:OptionalReagentInfos(recipeID, optionalAllocation) -> { { reagent = { itemID }, dataSlotIndex, quantity } }`:
  the slot's `dataSlotIndex` from the cached schematic; an item no slot lists is skipped. `GetLiveOperationInfo`
  builds its optional infos through it (behaviour unchanged; its specs stay green).
- Craft Next sends `Scanner:ToCraftingReagentInfo(recipeID, result.allocation)` followed by
  `Scanner:OptionalReagentInfos(recipeID, result.optionalAllocation)` to `CraftRecipe` (still the one call inside
  `Queue:CraftNext`); a missing optional is the entry's `"missing"` blocker.
- **Panel lines** (`FeatureLines`, `ProfessionPanel:RegisterLineProvider("optionals", fn)`), from
  `Recipes:BestOptionals(recipeID, charKey, {})`:
  - a pick: `{ L["Best optionals"], L["%s (+%s)"] }` (names joined with `ns.UI.JoinList`, `FormatMoney(gain)`);
  - no pick: `{ L["Best optionals"], L["none adds profit"] }`;
  - skipped > 0: `{ "", L["%d skipped: no price or no known effect"] }`;
  - nil: no lines.
- **Action** `ProfessionPanel:RegisterLineAction("queueOptionals", fn)`: `{ text = L["Queue with best optionals"],
  enabled = <a pick and the queue is writable>, onClick = Queue:Add{ recipeID, quantity = 1, charKey,
  optionalItemIDs = pick } }`; status `L["Queued with %s"]`.
- **Queue tab:** an entry with optionals adds `L["Optionals: %s"]` to its second line.

**Interfaces:**
- Consumes: Task 11's `BestOptionals`, `opts.optionalItemIDs`, `optionalAllocation`.
- Produces: `QueueEntry.optionalItemIDs`; `Scanner:OptionalReagentInfos`; panel provider `"optionals"`, action
  `"queueOptionals"`.

- [ ] **Step 1: Write the failing tests:** `stores sorted optional IDs on an entry`, `counts optional reagents in the
  missing reagents and the shopping list`; `sends the optional reagent infos to CraftRecipe` (`world.crafts[1]`
  reagents end with the optional's info and its `dataSlotIndex`), `reports a missing optional reagent as the
  blocker`; `OptionalReagentInfos maps items to their slot's dataSlotIndex`; feature lines: `shows the best
  optionals and the gain`, `shows none adds profit`, `adds nothing with optionalMode off`, `queues the recipe with the
  picked optionals`; queue tab: `names an entry's optionals`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite (the click-only specs included), locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-20. Craft Next with an optional.** Queue a recipe with "Queue with best optionals" and
  press Craft Next with the optional in your bags. Expected: the craft uses it (the result shows its effect; the bag
  count drops); with none in the bags Craft Next names it as missing.
- [ ] **Step 6: Commit** `feat: best optionals in the side panel, the queue and Craft Next`.

---

### Task 13: Craft lists and "Queue plan"

**Files:**
- Create: `Modules/CraftLists.lua` (module `CraftLists`, toggleable), `tests/craftlists/craft_lists_spec.lua`
- Modify: `UI/Tabs/Queue.lua` (section row `Tab.SECTIONS = { queue, lists }`, Lists section), `UI/Tabs/Planner.lua`
  (Queue plan button, `Tab.QueuePlan`), TOC, `Locales/enUS.lua`
- Test: `tests/ui/queue_tab_spec.lua`, `tests/ui/planner_tab_spec.lua`
- Docs: contract (CraftLists, QueueTab, PlannerTab), checklist P7-21

**Rules (decided):**
- **Limits:** 50 lists; 200 recipes per list; names trimmed, 1–40 characters, unique ignoring case.
- **API** (writers return nil plus `"readonly"` while `dbIsNewer`):
  - `Create(name) -> id | nil, "empty"|"duplicate"|"limit"|"readonly"`; `Rename(id, name) -> true | nil, err`;
    `Delete(id) -> boolean`; `GetLists() -> { CraftList }` (by name, ignoring case); `Get(id) -> CraftList|nil`.
  - `SetRules(id, rules)` repairs: `minProfit` a number ≥ 0 or nil; `minQuality` 1..5 or nil; `concentration` one of
    `"off"`, `"single"`, `"multi"` else `"off"`; `useOptionals` boolean.
  - `AddRecipe(id, recipeID, charKey|nil, quantity)` (the same recipe and charKey add up), `SetQuantity(id, index, n)`
    (≤ 0 removes), `FromQueue(name) -> id | nil, err` (the real queue entries, summed by recipeID and charKey).
- **`CraftLists:Plan(id, now) -> { entries = { QueueEntry-shaped }, skipped = { { recipeID, charKey, reason } } }`**
  (a pure read):
  - crafter = the recipe's `charKey`, else the best-profit crafter of `Recipes:WhoCanCraft` (the restock rule); none →
    `"noCrafter"`;
  - `result = Recipes:Evaluate(recipeID, crafter, { targetQuality = rules.minQuality })`: `flags.unreachableTarget` →
    `"unreachable"`; with `minProfit`, a nil profit → `"unknownProfit"`, a lower one → `"belowMinProfit"`;
  - `useOptionals`: the `BestOptionals` pick goes on the entries;
  - concentration `"off"`: every entry without it. `"single"`: per (crafter, skill line), the list recipe with the
    highest positive known `goldPerConcentration` (evaluated with `useConcentration = true`) gets
    `min(quantity, floor(pool.value / concentrationCost))` concentration crafts (`Alts:GetPools(now)`; an unknown pool
    gives 0), and the rest of its quantity is a second entry without concentration. `"multi"`:
    `ns.PlanCalc.Schedule(pools, concentrationResults, { maxCraftsPerRecipe = <that recipe's quantity> })` gives each
    recipe's concentration crafts, and the rest go without.
- `CraftLists:QueueList(id) -> added, skipped` adds the planned entries with `Queue:Add`; called from the Queue list
  button's click only.
- **Planner "Queue plan"** (Concentration section footer): `Tab.QueuePlan(rows) -> added, already`: each schedule row
  with `crafts > 0` is skipped when a real queue entry has the same recipeID, charKey and `useConcentration`, else
  `Queue:Add{ recipeID, quantity = crafts, charKey, useConcentration = true }`. Status `L["Queued %d crafts; %d were
  already queued"]`.
- **Lists section** (Queue tab): a section row `L["Queue"]` / `L["Lists"]` (session-only; default Queue, which is
  today's layout). Left: the lists (name, recipe count). Right: the selected list's recipes (Recipe, Character or
  `L["best crafter"]`, a quantity stepper, Remove); a rules row (`L["Min profit (gold)"]`, a `L["Min quality"]`
  stepper 0..5 where 0 is any, a concentration button cycling `L["Concentration: off"]` / `L["Concentration: single
  best"]` / `L["Concentration: across recipes"]`, a `L["Use best optionals"]` check); buttons `L["New from queue"]`
  (with a name box), `L["Rename"]`, `L["Delete"]` (a second click within 5 s confirms; the first shows `L["Click
  again to delete"]`; `Debounce("queueTab.delete", 5)` resets it), `L["Queue list"]` → status `L["Queued %d entries;
  %d skipped"]` with each skipped recipe and its reason in the tooltip.

**Interfaces:**
- Consumes: `Recipes:Evaluate`, `WhoCanCraft`, `BestOptionals` (Task 11), `Alts:GetPools`, `ns.PlanCalc.Schedule`,
  `Queue:Add`, `Planner:GetSchedule`.
- Produces: module `CraftLists` (API above); `ns.UI.QueueTab.SECTIONS` (Task 15 adds `gather`);
  `ns.UI.PlannerTab.QueuePlan`.

- [ ] **Step 1: Write the failing tests:** `creates, renames and deletes lists with their limits`, `refuses a duplicate
  name ignoring case`, `builds a list from the queue, summed by recipe and character`, `plans each skip reason`,
  `single best gives concentration to the best gold per point up to the pool`, `across recipes follows
  PlanCalc.Schedule`, `adds the best optionals with useOptionals`, `QueueList adds the planned entries`, `writes
  nothing while the saved data is from a newer version`; Planner tab: `queues every schedule row with
  concentration`, `skips rows already queued`; Queue tab: `switches to Lists and back`, `creates a list from the
  queue`, `queues a list and lists the skipped ones in the tooltip`, `deletes only on the second click`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-21. Lists and the plan.** Make a list from the queue, set Min profit and
  "Concentration: single best", clear the queue and press Queue list. Expected: the profitable recipes come back,
  one with concentration up to what that character has; the Planner's Queue plan adds the schedule's crafts once.
- [ ] **Step 6: Commit** `feat: saved craft lists with rules, and Queue plan from the concentration schedule`.

---

### Task 14: Intermediate crafts

**Files:**
- Create: `Modules/Intermediates.lua` (module `Intermediates`, toggleable), `tests/intermediates/resolve_spec.lua`
- Modify: `Modules/Recipes.lua` (`opts.reagentPrices`), `Modules/Queue.lua` (`Add(entry, opts)` with `opts.before`;
  `entry.parentID`), `UI/FeatureLines.lua` (panel provider `"intermediates"`, action `"queueSubCrafts"`),
  `UI/Tabs/Queue.lua` (child marker), TOC, `Locales/enUS.lua`
- Test: `tests/recipes/evaluate_spec.lua`, `tests/queue/queue_spec.lua`, `tests/ui/feature_lines_spec.lua`
- Docs: contract (Recipes, Queue, Intermediates), checklist P7-22

**Rules (decided):**
- **`opts.reagentPrices = { [itemID] = copper }`** (Recipes): a non-empty table is read before `full_opts` (as
  `extraStats`); such a call neither reads nor writes the cache; those values replace `Prices:Get` for reagents only
  (never outputs), and their `PriceResult` is `{ value, source = "craft" }` (never stale, no age).
- **Recursion:** `MAX_DEPTH = 3`, the path set, `MAX_NODES = 50` and the memo, as in "Decisions". The cost formula is
  there too.
- **`Intermediates:Resolve(recipeID, charKey, opts) -> Resolution|nil`** (nil without a schematic):
  `Resolution = { rows = { ReagentRow }, reagentPrices = { [itemID] = copper }, result = RecipeResult|nil, base =
  RecipeResult, saving = copper|nil, truncated = boolean }`;
  `ReagentRow = { itemID, quantity, buy = copper|nil, craft = { recipeID, quality, charKey, unit = copper|nil, yield,
  depth, children = { ReagentRow } } | nil, choice = "craft"|"buy"|nil, chosenBy = "user"|"cheaper", cycle = boolean }`.
  - Rows: the reagents of the plain allocation of `base = Evaluate(recipeID, charKey, opts)` that
    `Recipes:FindRecipesForItem` knows; `quantity` per craft; `buy = Prices:Get(itemID).value`.
  - `choice`: `intermediateChoices[itemID]` when set (`chosenBy = "user"`), else the cheaper of `craft.unit` and `buy`
    (a nil side loses; both nil → nil).
  - `reagentPrices[itemID] = craft.unit` for rows with `choice == "craft"` and a number unit; `result =
    Evaluate(recipeID, charKey, opts + { reagentPrices })` when that is non-empty; `saving = base.reagentCost -
    result.reagentCost` when both are numbers.
- `Intermediates:CraftOption(itemID) -> { recipeID, quality, charKey, unit, yield } | nil` (the depth-0 craft of one
  item; Task 15 uses it). `SetChoice(itemID, "craft"|"buy"|nil)`, `GetChoice(itemID)`.
- **`Queue:Add(entry, opts)`**: `opts.before = <stored id>` inserts the new entry at that entry's index (unknown id:
  appended); `entry.parentID` is stored when it is a number.
- **`Intermediates:QueueSubCrafts(spec) -> { parentID, subIDs } | nil, reason`**,
  `spec = { recipeID, quantity, charKey, targetQuality?, useConcentration?, queueID? }`:
  - the parent is `spec.queueID` when it is a stored entry, else it is added first with `Queue:Add`;
  - then, depth first and post-order (a sub-craft's own sub-crafts first), for each row with `choice == "craft"`:
    `short = quantity * spec.quantity - Scanner:GetOwnedCount(itemID, spec.charKey, queueUseWarband)`; when
    `short > 0`, `crafts = ceil(short / craft.yield)` and `Queue:Add({ recipeID = craft.recipeID, quantity = crafts,
    charKey = craft.charKey, targetQuality = craft.quality, parentID = <its parent's id> }, { before = <that id> })`;
  - every sub-entry ends up before the entry that needs it, so Craft Next (queue order) makes it first;
  - `reason`: `"readonly"`, `"noSchematic"` or `"nothing"` (no sub-craft needed).
- **Panel lines** (`"intermediates"`, at most 6 rows then `L["+%d more"]`): `{ <item name>, L["craft %s · buy %s ·
  %s"] }` with `FormatMoney` (nil → `"?"`) and `L["crafting"]` / `L["buying"]` / `L["buy only (cycle)"]`; then
  `{ L["With intermediates"], L["saves %s per craft"] }` when `saving > 0`. **Action** `"queueSubCrafts"`:
  `L["Queue with sub-crafts"]`, enabled when a row is chosen to craft; `onClick` →
  `QueueSubCrafts({ recipeID, quantity = 1, charKey })`; status `L["Queued %d sub-crafts first"]`, plus
  `L["%s crafts on %s: mail the reagents"]` when a sub-crafter is another character.
- **Queue tab:** an entry with a `parentID` starts with `"\226\134\179 "` (↳).

**Interfaces:**
- Consumes: `Recipes:Evaluate`, `FindRecipesForItem`, `WhoCanCraft`, `Prices:Get`, `Scanner:GetOwnedCount`, `Queue:Add`.
- Produces: `opts.reagentPrices`; `Queue:Add(entry, opts)`, `QueueEntry.parentID`; module `Intermediates` with
  `Resolve`, `CraftOption`, `SetChoice`, `GetChoice`, `QueueSubCrafts`, `MAX_DEPTH`, `MAX_NODES`;
  `db.global.intermediateChoices`.

- [ ] **Step 1: Write the failing tests** (`make_world` gains recipe 9100 that makes reagent 1001 from 1101):

```lua
it("treats a reagent already on the path as buy only", function()
  -- 9100 makes 1001 from 1101; 9101 makes 1101 from 1001
  local row = I:Resolve(9001, "Main-Realm").rows[1]
  assert.is_true(row.craft.children[1].cycle); assert.is_nil(row.craft.children[1].craft)
end)
it("stops at depth 3", function()
  -- a chain 9001 <- 9100 <- 9101 <- 9102 <- 9103
  assert.is_nil(deepest(I:Resolve(9001, "Main-Realm")).craft)   -- the fourth level is buy only
end)
it("evaluates at most 50 sub-recipes per resolution", function()
  local spy = spy_on_evaluate(); I:Resolve(wide_recipe, "Main-Realm")
  assert.is_true(spy.subCalls <= 50); assert.is_true(I:Resolve(wide_recipe, "Main-Realm").truncated)
end)
it("queues sub-crafts ahead of the parent in dependency order", function()
  local r = I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
  assert.same({ "9101", "9100", "9001" }, recipe_order(Q:GetEntries()))
  assert.equals(r.parentID, Q:GetEntries()[2].parentID)
end)
```
  and `offers craft when a character can make the reagent`, `uses the cheaper of craft and buy without a choice`,
  `follows the player's choice`, `costs a crafted item net of resourcefulness per expected yield`, `passes
  sub-reagent costs down`, `leaves the unit cost nil when the sub-recipe has no price`, `queues nothing for a reagent
  already held`; `reagentPrices overrides reagent prices without touching the cache`; `inserts an entry before
  another`; feature lines: `lists craft against buy for each craftable reagent`, `queues sub-crafts from the
  action`; `SetChoice writes nothing while the saved data is from a newer version`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-22. Sub-crafts.** Pick a recipe whose reagent you can craft cheaper than the AH (the panel
  says "crafting"). Press "Queue with sub-crafts", then Craft Next repeatedly. Expected: the reagent's craft comes
  first, then the parent, with no bought reagent.
- [ ] **Step 6: Commit** `feat: intermediate crafts (craft or buy per reagent, sub-crafts queued first)`.

---

### Task 15: Gathering plan

**Files:**
- Modify: `Modules/Queue.lua` (new `GetGatheringPlan`), `UI/Tabs/Queue.lua` (`gather` section), `Locales/enUS.lua`
- Test: `tests/queue/gather_spec.lua` (new), `tests/ui/queue_tab_spec.lua`
- Docs: contract (Queue, QueueTab), checklist P7-23

**Rules (decided):**
- `Queue:GetGatheringPlan(charKey|nil) -> { GatherRow }`: one row per item of `GetMissingReagents(charKey)` (what is
  missing after everything the crafter holds, bank and warband included), sorted by item name, then itemID.
  `GatherRow = { itemID, need, sources = { GatherSource }, choice = Intermediates:GetChoice(itemID) | nil }`,
  `GatherSource = { kind, charKey?, count?, unitPrice?, ageSeconds?, recipeID?, quality? }`, kinds in this order:
  1. `"mail"`: each character with `Scanner:GetMailCount(itemID, c) > 0` (count, age);
  2. `"alt"`: each other visible character holding it (`Alts:GetHoldings(itemID).chars` while Alts is on, else
     `Scanner:GetItemCount(itemID, c)` bags + bank), with its data age;
  3. `"warband"`: only while `queueUseWarband` is off and the warband holds some;
  4. `"craft"`: `Intermediates:CraftOption(itemID)` while Intermediates is on (unit cost, crafter, recipe, quality);
  5. `"vendor"`: `Prices:Get(itemID)` with `source == "vendor"`;
  6. `"ah"`: `source == "auction"`, `ageSeconds = ageDays * 86400`.
  A source with an unknown count or price keeps nil there (shown `"?"`).
- **Gather section** (third section button `L["Gather"]`): Item (flexible), Need, Sources (the first two as
  `L["%s %d (%s)"]` kind label, count, short character; prices as `CompactMoney`), a choice button on rows with a
  craft source cycling `L["Auto"]` → `L["Craft"]` → `L["Buy"]` (`Intermediates:SetChoice` nil / craft / buy), a
  `L["Queue craft"]` button on craft rows (`Queue:Add{ recipeID, quantity = ceil(need / yield), charKey, targetQuality
  = quality }`), a `L["Characters: all"]` / `L["Characters: this one"]` toggle and the existing Shopping List button.
  The row tooltip lists every source with its age (`L["%s ago"]`, red past `Alts` `staleDays`).
- Kind labels: `L["Mail"]`, `L["Alt"]`, `L["Warband bank"]`, `L["Craft"]`, `L["Vendor"]`, `L["Auction house"]`.

**Interfaces:**
- Consumes: `Scanner:GetMailCount` (6), `Intermediates:CraftOption`, `SetChoice`, `GetChoice` (14), `Alts:GetHoldings`,
  `Prices:Get`.
- Produces: `Queue:GetGatheringPlan`; `ns.UI.QueueTab.SECTIONS` gains `gather`.

- [ ] **Step 1: Write the failing tests:** `lists mail, alts, craft, vendor and AH sources in that order`, `shows the
  warband only with queueUseWarband off`, `leaves craft out while Intermediates is off`, `keeps an unknown count as
  nil`, `limits the plan to one character`; Queue tab: `cycles the choice and stores it`, `queues the reagent's
  craft`, `marks old snapshots with their age in the tooltip`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-23. Where to get reagents.** With a queue short of three reagents (one in an alt's bags,
  one craftable, one only on the AH), open Queue › Gather. Expected: each row names that source first, with the alt's
  data age; Craft/Buy flips the choice and the side panel's intermediate line follows.
- [ ] **Step 6: Commit** `feat: gathering plan for missing reagents`.

---
## Getting reagents, chat requests and key bindings (Tasks 16–20)

### Task 16: Bank and warband-bank pull

**Files:**
- Create: `UI/BankPull.lua` (module `BankPull`, toggleable; frame `FabricationStationBankPull`),
  `tests/ui/bank_pull_spec.lua`, `tests/ui/bank_pull_click_only_spec.lua`
- Modify: `Modules/Queue.lua` (new `GetRequired`), `Modules/Recipes.lua` (`DEFAULTS.bankPullUseWarband = true` and a
  toggle), `tests/helpers/wow_stubs.lua` (`C_Container.UseContainerItem`, `SplitContainerItem`,
  `PickupContainerItem` recording `W.containerOps`; `GetContainerNumFreeSlots`; `GetCursorInfo` → nil;
  `ClearCursor`), `.luacheckrc` (`GetCursorInfo`, `ClearCursor`, `BankFrame`), TOC, `Locales/enUS.lua`
- Docs: contract (Queue, BankPull), checklist P7-24, P7-25

**Rules (decided):**
- `Queue:GetRequired(charKey) -> { [itemID] = qty }`: `per_craft(entry) * quantity` summed over that character's
  entries, real and restock, before any holdings (the shared local of `shortfalls`).
- `BankPull:Plan() -> { { itemID, need, bags, inBank, inWarband } }` for the logged-in character: `bags` is the live
  `C_Item.GetItemCount(itemID, false, false, false, false)`; `need = required - bags`; `inBank` counts the
  `CharacterBankTab_1..6` slots; `inWarband` counts `AccountBankTab_1..5` only while `bankPullUseWarband` and
  `C_Bank.CanViewBank(Enum.BankType.Account)`. Rows with `need > 0` and `inBank + inWarband > 0`, by itemID.
- `BankPull:Step() -> { status, itemID?, count? }`, the only caller of the three container moves (the calls it may
  make are listed under "Decisions"). Checks in this order:
  1. `"closed"` unless `Scanner.bankOpen`;
  2. `"combat"` while `InCombatLockdown()`;
  3. `"cursorBusy"` while `GetCursorInfo()` returns anything;
  4. `"inFlight"` after a move until the next `BAG_UPDATE_DELAYED`, or 3 s (`Debounce("bankPull.flight", 3)`);
  5. `"done"` when the plan is empty.
- Then the first plan row, bank tabs before warband tabs, skipping `isLocked` slots (all of them locked: `"locked"`):
  - the largest stack with `stackCount <= need` → `C_Container.UseContainerItem(bag, slot)` → `"moved"` (needs a free
    bag slot, else `"bagsFull"`);
  - else the smallest stack → the first empty slot of Backpack..Bag_4, then the reagent bag (`"bagsFull"` without
    one) → `C_Container.SplitContainerItem(bag, slot, need)` then `C_Container.PickupContainerItem(freeBag,
    freeSlot)` → `"split"`. When `GetCursorInfo()` still holds an item after the pickup, `ClearCursor()` returns it
    and the result is `"bagsFull"`.
  - Any move sets the in-flight flag. One press makes at most one move.
- **Panel:** shown on `BANKFRAME_OPENED` when the plan has rows (nothing else happens on open), refreshed on
  `BAG_UPDATE_DELAYED` (`Debounce("bankPull.refresh", 0.2)`), hidden on `BANKFRAME_CLOSED`. Anchored to `BankFrame`'s
  TOPRIGHT (outside) when `BankFrame` exists, else `UIParent` TOP. Up to 6 lines `L["%s: %d of %d in the bank"]`
  (`need` capped at what the bank holds); a button `L["Retrieve (%d left)"]`, disabled in combat and in flight,
  whose `OnClick` calls `BankPull:Step()` directly; a status line: `L["Moved %d %s"]`, `L["Bags are full"]`,
  `L["Put down the item on your cursor first"]`, `L["Not in combat"]`, `L["Everything the queue needs is in your
  bags"]`, `L["That stack is locked; try again"]`.
- **Structural** (`tests/helpers/click_only.lua`): the three container calls only inside `function BankPull:Step`
  in `UI/BankPull.lua`; `BankPull:Step` referenced only from an `OnClick` handler in `UI/BankPull.lua`.

**Interfaces:**
- Consumes: `Scanner.bankOpen`, `per_craft` (Queue), `click_only` (Task 5).
- Produces: `Queue:GetRequired(charKey)`; module `BankPull` with `Plan`, `Step`.

- [ ] **Step 1: Write the failing tests** (fake bank tabs in `C_Container`; `W.containerOps`):

```lua
it("never moves more than the shortfall over repeated presses", function()
  required(1001, 5); bank_stacks(1001, { 3, 20 }); bags(1001, 0)
  assert.equals("moved", BP:Step().status)            -- the stack of 3
  W.fire("BAG_UPDATE_DELAYED"); bags(1001, 3)
  local r = BP:Step(); assert.equals("split", r.status); assert.equals(2, r.count)
  W.fire("BAG_UPDATE_DELAYED"); bags(1001, 5)
  assert.equals("done", BP:Step().status)
  assert.equals(5, moved_total(W.containerOps, 1001))
end)
it("moves nothing while the last move is in flight", function()
  BP:Step(); assert.equals("inFlight", BP:Step().status); assert.equals(1, #W.containerOps)
end)
it("refuses while the cursor holds an item", function() end)
```
  and `does nothing on BANKFRAME_OPENED but show the panel` (`W.containerOps` empty), `is closed without the bank`,
  `refuses in combat`, `uses the warband only with bankPullUseWarband and a viewable warband bank`, `skips locked
  stacks and says when all are locked`, `returns the split to its slot when no bag slot took it`, `leaves the in-flight
  state after 3 s`, `cancels its debounce keys on disable`; structural: `calls the container moves only inside
  BankPull:Step`, `references BankPull:Step only from an OnClick handler`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, luacheck, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-24. Retrieve from the bank.** Queue crafts that need 5 of a reagent you hold 3 + 20 of in
  the bank (none in bags). Press Retrieve three times. Expected: 3 move, then 2 split off, then "Everything the queue
  needs is in your bags"; nothing moves on opening the bank; in combat the button is disabled. Repeat with the warband
  bank. Also report: does Craft Next craft with reagents left in the bank or warband bank (no Retrieve)? If yes, the
  pull matters only for moving reagents to mail to an alt. **P7-25. Bank panel place.** Expected: the panel sits next
  to the bank window, on the character and the warband tabs.
- [ ] **Step 6: Commit** `feat: retrieve the queue's shortfall from the bank and warband bank, one move per click`.

---

### Task 17: Merchant "Buy for queue"

**Files:**
- Create: `UI/MerchantBuy.lua` (module `MerchantBuy`, toggleable; frame `FabricationStationMerchantBuy`),
  `tests/ui/merchant_buy_spec.lua`, `tests/ui/merchant_click_only_spec.lua`
- Modify: `tests/helpers/wow_stubs.lua` (`GetMerchantNumItems` → 0, `GetMerchantItemID`, `C_MerchantFrame.GetItemInfo`,
  `GetMerchantItemInfo`, `GetMerchantItemMaxStack`, `BuyMerchantItem` recording `W.bought`), `.luacheckrc`
  (`GetMerchantNumItems`, `GetMerchantItemID`, `GetMerchantItemInfo`, `C_MerchantFrame`, `GetMerchantItemMaxStack`,
  `BuyMerchantItem`, `MerchantFrame`), TOC, `Locales/enUS.lua`
- Docs: contract (MerchantBuy), checklist P7-26

**Rules (decided):**
- `MerchantBuy:Plan() -> { rows = { { index, itemID, need, buy, unitPrice, cost } }, total, affordable }`:
  - `need` = `Queue:GetMissingReagents(ns.FS:CharKey())[itemID]` for each merchant index whose `GetMerchantItemID`
    is a missing reagent;
  - item info from `C_MerchantFrame.GetItemInfo(index)` (`price`, `stackCount`, `numAvailable`, `isPurchasable`,
    `hasExtendedCost`), else `GetMerchantItemInfo(index)`'s returns 3–6 and 8 (unverified, P7-26);
  - skipped: extended cost, not purchasable, `numAvailable == 0`, price not a positive number;
  - `s = max(1, stackCount)`: `buy = ceil(need / s) * s`, capped at `numAvailable * s` when `numAvailable > 0` (−1 is
    unlimited); `unitPrice = price / s`; `cost = (buy / s) * price`;
  - `total` = Σ cost; `affordable = total <= GetMoney()`.
- `MerchantBuy:Buy() -> { status = "bought"|"nothing"|"poor"|"closed"|"combat"|"inFlight", count?, cost? }`, the only
  caller of `BuyMerchantItem`: `"closed"` unless the merchant is open (`MERCHANT_SHOW` / `MERCHANT_CLOSED`);
  `"combat"`; `"inFlight"` until the next `BAG_UPDATE_DELAYED` after a buy, or 3 s
  (`Debounce("merchantBuy.flight", 3)`); the plan is computed again; `"poor"` buys nothing when `affordable` is
  false; else per row, calls of `BuyMerchantItem(index, q)` with `q = min(remaining, GetMerchantItemMaxStack(index))`
  rounded down to a multiple of `s` (at least `s`), at most 20 calls per click; `"nothing"` with no rows.
- **Panel:** shown on `MERCHANT_SHOW` when the plan has rows (nothing is bought), refreshed on `MERCHANT_UPDATE` and
  `BAG_UPDATE_DELAYED` (`Debounce("merchantBuy.refresh", 0.2)`), hidden on `MERCHANT_CLOSED`; anchored outside
  `MerchantFrame`'s TOPRIGHT. Up to 6 lines `L["%s: %d for %s"]`; a button `L["Buy %d reagents for %s"]`, disabled
  when not affordable (tooltip `L["Not enough gold"]`), in combat or in flight, whose `OnClick` calls
  `MerchantBuy:Buy()` directly; status `L["Bought %d reagents for %s"]`.
- **Structural:** `BuyMerchantItem` only inside `function MerchantBuy:Buy` in `UI/MerchantBuy.lua`;
  `MerchantBuy:Buy` referenced only from an `OnClick` handler there.

**Interfaces:**
- Consumes: `Queue:GetMissingReagents`, `click_only` (Task 5).
- Produces: module `MerchantBuy` with `Plan`, `Buy`.

- [ ] **Step 1: Write the failing tests:** `rounds up to the merchant's stack size` (need 7, stack 5 → buy 10, cost
  2 × price), `buys nothing when the gold on hand is short`, `skips extended-cost and sold-out items`, `splits a buy
  into max-stack calls`, `buys only this character's missing reagents`, `buys nothing on MERCHANT_SHOW`, `refuses a
  second click before the bags update`, `is closed without a merchant`, `falls back to GetMerchantItemInfo`;
  structural: `calls BuyMerchantItem only inside MerchantBuy:Buy`, `references MerchantBuy:Buy only from an OnClick
  handler`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, luacheck, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-26. Buy at a merchant.** Queue a craft that needs a vendor reagent sold in stacks (and one
  sold singly), visit the vendor. Expected: the panel lists both with the total; one click buys exactly the missing
  count rounded up to the stack; nothing is bought on opening; with too little gold the button is disabled. Report
  whether `C_MerchantFrame.GetItemInfo` exists and whether `BuyMerchantItem`'s quantity counted items or stacks.
- [ ] **Step 6: Commit** `feat: buy the queue's vendor reagents at a merchant with one click`.

---

### Task 18: Chat-request inbox

**Files:**
- Create: `Modules/Social/ChatInbox.lua` (module `ChatInbox`, toggleable, options group `chatInbox` 82),
  `UI/Tabs/Requests.lua` (core registrar `RequestsTab`, tab `"requests"`, `L["Requests"]`, order 95, phase 7),
  `tests/social/chat_inbox_spec.lua`, `tests/ui/requests_tab_spec.lua`
- Modify: `Core/Bus.lua` (`INBOX_CHANGED = "FS_INBOX_CHANGED"`), TOC, `Locales/enUS.lua`
- Docs: contract (ChatInbox, tabs, options), checklist P7-27

**Rules (decided):**
- **Settings** (`SettingsAccessor("chatInbox")`): `dismissMinutes` 5..240 (30), `keepDays` 1..30 (7), `keepHistory`
  boolean (true); numbers rounded and clamped, wrong types get the default.
- **Capture** (`FS_CHATSCAN_MATCH(match)`; handlers `Wrap("ChatInbox", ...)`):
  - an `open` or `replied` entry from the same sender younger than `dismissMinutes` takes the match: its new recipes
    are appended (unique by recipeID), `text` becomes the newer one, `time` moves, and with `keepHistory` an `"in"`
    line is added;
  - else a new entry `{ status = "open", seenBy = ns.FS:CharKey(), ... }` (cap 100; the oldest goes).
- **Whispers:** `CHAT_MSG_WHISPER(text, sender)` and `CHAT_MSG_WHISPER_INFORM(text, target)`. `issecretvalue` is
  asked of the text and the name before anything else touches them (a secret value skips the event). The name goes
  through `ns.Social.Util.NormalizeName`. The newest `open` or `replied` entry for that name, at most 24 h old, gets
  an `"in"` line (WHISPER), or an `"out"` line plus `status = "replied"` and `statusTime` (INFORM). Lines are cut at
  255 bytes without splitting a UTF-8 character; at most 20 per entry (the oldest goes); none with `keepHistory` off.
- **Expiry and pruning:** an `open` entry older than `dismissMinutes` reads as `"expired"` (stored as such when
  writable); entries older than `keepDays` are pruned at enable and on every add.
- **API:** `GetEntries(opts) -> { InboxEntry }` newest first (`opts.status = { [status] = true }` filters),
  `Latest() -> InboxEntry|nil` (the newest `open`), `Dismiss(id) -> boolean`, `Reply(id) -> true | false, reason`
  (`"none"`|`"noChat"`): `ChatFrameUtil.SendTellWithMessage(entry.sender,
  ChatScan:GetWhisperTemplate():format(<first recipe's link or name>))`, else `ChatFrameUtil.SendTell(sender)`; it
  fills the chat box and sends nothing (the stubs' `SendChatMessage` raises). Every write sends `FS_INBOX_CHANGED`.
- **Requests tab:** an `ExpandGrid` with When (`FormatAge`), Sender (flexible), Recipe (the first, badge `"+N"`),
  Status (`L["open"]`, `L["replied"]`, `L["dismissed"]`, `L["expired"]`), Seen on (short character). The detail shows
  the request text and the history (`L["%s ago, %s: %s"]` with `L["they"]` / `L["you"]`), and Reply / Dismiss
  buttons whose `OnClick` call `ChatInbox:Reply(id)` / `Dismiss(id)`. A `L["Show: open"]` / `L["Show: all"]` toggle
  (session-only). ChatInbox or ChatScan off → `L["Chat requests are off: turn on ChatScan and ChatInbox in Settings >
  Modules"]`. Every peer string goes through `EscapePipes`. Refresh on `FS_INBOX_CHANGED` (0.5 s debounce,
  `requestsTab.refresh`).

**Interfaces:**
- Consumes: `FS_CHATSCAN_MATCH` (`ChatMatch`), `ChatScan:GetWhisperTemplate`, `ns.UI.ExpandGrid`.
- Produces: module `ChatInbox` (`Settings`, `GetEntries`, `Latest`, `Dismiss`, `Reply`); `ns.Msg.INBOX_CHANGED`; tab
  `requests`. Task 19's reply binding calls `Latest` and `Reply`.

- [ ] **Step 1: Write the failing tests:** `keeps a match as an open entry`, `merges a second request from the same
  sender`, `caps the inbox at 100 entries`, `expires an open entry after dismissMinutes`, `prunes entries older than
  keepDays`, `adds whisper lines and marks the entry replied`, `skips a whisper with a secret text or name`, `stores no
  history with keepHistory off`, `cuts a history line without splitting a character`, `Latest is the newest open
  entry`, `Reply fills the chat box and sends nothing` (`W.tells`), `Dismiss changes the status`, `writes nothing while
  the saved data is from a newer version`; tab: `lists open requests newest first`, `shows the history in the detail`,
  `Reply and Dismiss buttons act on their entry`, `shows all with the toggle`, `escapes pipes in sender and text`,
  `says when the inbox is off`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-27. Request inbox.** Let a trade-chat request match, whisper the sender from the Requests
  tab (Reply, then Enter), get an answer. Expected: the entry turns "replied" and its detail shows both lines; another
  character sees the same entry with "Seen on" naming the first; after 30 minutes an unanswered one reads "expired";
  in an instance nothing errors.
- [ ] **Step 6: Commit** `feat: chat-request inbox with reply status and whisper history`.

---

### Task 19: Key bindings

**Files:**
- Create: `Bindings.xml` (repo root), `UI/Bindings.lua` (core registrar module `Bindings`), `tests/ui/bindings_spec.lua`
- Modify: `UI/OrdersPanel.lua` (`M.ClickClaim()`), `.luacheckrc` (`globals`: `FabricationStation_Binding`,
  `BINDING_HEADER_FABRICATIONSTATION`, the four `BINDING_NAME_FABRICATIONSTATION_*`), `tests/release/release_config_spec.lua`
  (line 232's shipped-files list gains `Bindings.xml`), TOC, `Locales/enUS.lua`
- Docs: contract (Bindings, OrdersPanel), checklist P7-28

**Rules (decided):**
- **`Bindings.xml`**, exactly four bindings, each body one call:
  ```xml
  <Bindings>
    <Binding name="FABRICATIONSTATION_CRAFTNEXT" header="FABRICATIONSTATION" category="ADDONS">FabricationStation_Binding("craftNext")</Binding>
    <Binding name="FABRICATIONSTATION_CLAIMBEST" category="ADDONS">FabricationStation_Binding("claimBest")</Binding>
    <Binding name="FABRICATIONSTATION_TOGGLE" category="ADDONS">FabricationStation_Binding("toggle")</Binding>
    <Binding name="FABRICATIONSTATION_REPLYLATEST" category="ADDONS">FabricationStation_Binding("replyLatest")</Binding>
  </Bindings>
  ```
- **`UI/Bindings.lua`** at file load sets `BINDING_HEADER_FABRICATIONSTATION = L["FabricationStation"]` (a new key; its
  context comment says to keep the addon name), and `BINDING_NAME_FABRICATIONSTATION_CRAFTNEXT = L["Craft Next"]`,
  `_CLAIMBEST = L["Claim Best Order"]`, `_TOGGLE = L["Open or close FabricationStation"]`, `_REPLYLATEST = L["Reply to
  the latest chat request"]`. It defines the global `FabricationStation_Binding(id)` =
  `ns.FS:SafeCall("Bindings:Run", run, id)` (log-only) and creates the hidden own button
  `FabricationStationCraftNextProxy`.
- **`run(id)`** (unknown ids do nothing):
  - `craftNext`: in combat prints `L["Not in combat"]`; else `FabricationStationCraftNextProxy:Click()`. The proxy's
    `OnClick` (`Wrap("Bindings:CraftNext", ...)`) calls `queue:CraftNext()` directly and shows the result through
    `ProfessionPanel:SetStatus(ns.UI.QueueTab.StatusText(result, ...), tone)` when the panel is shown, else prints the
    same text.
  - `claimBest`: in combat as above; else `ns.UI.OrdersPanel.ClickClaim()`, which calls `side.claim:Click()` and returns
    true when the side panel exists and its claim button is shown and enabled; false prints `L["Open the crafting
    orders board to claim an order"]`. `ClickClaim` names no `ClaimBest` token, so the claim rule is unchanged.
  - `toggle`: `MainWindow:Toggle()`.
  - `replyLatest`: `ChatInbox:Latest()` and `ChatInbox:Reply(id)` while ChatInbox is on; else prints `L["No open chat
    request"]`.
- The craft rule ("Queue:CraftNext only from OnClick handlers") and the claim rule stay green unchanged; a new case
  checks `Bindings.xml`: every `<Binding>` body is `FabricationStation_Binding("<id>")` with one of the four ids, every
  name has a `BINDING_NAME_` global set in `UI/Bindings.lua`, and no body names another function.

**Interfaces:**
- Consumes: `Queue:CraftNext`, `ns.UI.QueueTab.StatusText`, `ProfessionPanel:SetStatus`, `MainWindow:Toggle`,
  `ChatInbox:Latest`/`Reply` (Task 18).
- Produces: `FabricationStation_Binding`, `ns.UI.OrdersPanel.ClickClaim()`, `FabricationStationCraftNextProxy`.

- [ ] **Step 1: Write the failing tests:** `sets the header and the four binding names`, `craftNext clicks the proxy,
  which crafts once` (`world.crafts` has one call), `claimBest clicks the shown claim button`, `claimBest says to open
  the board when the side panel is hidden`, `refuses craftNext and claimBest in combat`, `toggle opens and closes the
  window`, `replyLatest fills the chat box for the newest open request`, `replyLatest says when there is none`, `an
  error in a binding is logged, never raised`; `Bindings.xml calls only FabricationStation_Binding with a known id`;
  release: `ships Bindings.xml`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** focused, full suite (both click-only specs), luacheck, locale check. Expected: PASS.
- [ ] **Step 5: Docs.** **P7-28. Key bindings.** Key Bindings › AddOns › FabricationStation lists four bindings; bind
  each. Expected: Craft Next crafts one queued item with the profession open; Claim Best Order claims with the board
  open (no "action blocked" or "interface action failed"); the toggle opens the window; the reply key fills the chat
  box with the newest request. In combat the first two print "Not in combat".
- [ ] **Step 6: Commit** `feat: key bindings for Craft Next, Claim Best Order, the window and chat replies`.

---

### Task 20: Phase 7 integration and docs

**Files:**
- Create: `tests/integration/phase7_spec.lua`
- Modify: `tests/integration/load_all_spec.lua` (the new files), `CHANGELOG.md`, `README.md`, the interface contract
  (a sweep), `docs/in-game-checklist.md` (P7-29)
- Test: `tests/release/docs_spec.lua` (120 columns)

**Rules (decided):**
- `phase7_spec.lua` (full `load_addon` + `W.boot()`):
  - every new module exists; `SaleLog`, `CraftLog`, `CraftLists`, `Intermediates`, `ChatInbox`, `ReadyAlerts`,
    `MerchantBuy`, `BankPull` are enabled and not core; `FeatureLines`, `RequestsTab`, `Bindings` are core;
  - no diagnostics error after boot;
  - disabling and re-enabling each of the eight leaves `W.registrations(module)` empty and no pending debounce key with
    its prefix (`saleLog.`, `readyAlerts.`, `merchantBuy.`, `bankPull.`), and gives back the same registrations;
  - `FS_DATA_CHANGED` ×50 runs `readyAlerts.schedule` once;
  - with `dbIsNewer`, one event of every new source (`OWNED_AUCTIONS_UPDATED`, `AUCTION_HOUSE_AUCTION_CREATED`,
    `MAIL_INBOX_UPDATE`, `TRADE_SKILL_ITEM_CRAFTED_RESULT`, `FS_CHATSCAN_MATCH`, `CHAT_MSG_WHISPER_INFORM`) leaves
    `db.global` unchanged (`DeepCopy` compare).
- **CHANGELOG** gets a "Phase 7" section in the user's words (one line per §9c group). **README**: the feature list
  gains the §9c items; the "never does" list keeps "never crafts, claims, posts, buys, sends chat or moves items for
  you" and adds "never refreshes the order board on a timer". Both stay within 120 columns.
- **Contract sweep:** every task's bullets present and consistent with the Interfaces blocks; `ordersSnapshot` lines
  marked "[phase 7 Task 1] replaced by `orderBoards`".

- [ ] **Step 1: Write the failing tests** (`phase7_spec.lua` as above; `load_all_spec.lua` lists the new files).
- [ ] **Step 2: Run.** Expected: FAIL only where a task left a gap; fix it in the owning file.
- [ ] **Step 3: Write** CHANGELOG, README and the contract sweep.
- [ ] **Step 4: Run** the full suite, luacheck, locale check, `lua tools/check_release.lua` if it runs offline.
  Expected: all green.
- [ ] **Step 5: Docs.** **P7-29. Phase 7 smoke.** On two characters: open both boards, price a patron order, shop two
  selected orders, post and cancel an auction, craft a Multicraft recipe, queue a list, queue sub-crafts, retrieve at
  the bank, buy at a vendor, reply to a chat request with the key. Expected: no Lua error (`/console scriptErrors 1`),
  nothing in Settings › Diagnostics, and each step does what its P7 line says.
- [ ] **Step 6: Commit** `test: phase 7 integration; docs: CHANGELOG, README and contract for phase 7`.

---

## Self-review notes

- **Scope coverage** (scope item → task):
  1 C1 → 2; 2 C2 → 6 (data), 7; 3 C6 → 4; 4 V8 → 19; 5 V5 → 5 (with the manual Refresh button, per the ruling); 6 C15
  → 17; 7 C3 → 11, 12; 8 C4 → 13; 9 C5 → 1, 3; 10 V7 → 18; 11 C12 → 6, 8; 12 C11 → 9, 10 (with Appendix A #1 and #8);
  13 C13 → 14 (choice UI also in 15); 14 C14 → 15, 16.
- **Rulings applied:** no automation (every protected or moving call has one owner and a structural spec); no board
  auto-refresh; no TSM or Syndicator; own frames and post-hooks only; unknown is nil; one migration (3) for the only
  shape change, lazy tables for the rest, nothing wiped (`ordersSnapshotLegacy`); every string a whole key; every
  in-game assumption a P7 line (P7-1 to P7-29, pre-assigned).
- **Cut or narrowed, by this plan:**
  - per-profession knowledge point values (C1): the existing single `knowledgePointValue` is the setting;
  - multi-select on Blizzard's board rows (C6): Orders tab only, which already spans every character;
  - the profession filter of the tracker (C5): the existing type, risk and score filters plus the character scope;
  - Syndicator stock (C2): own listings and mail only;
  - craft-list editing beyond "new from queue", quantities and removal (C4);
  - board Refresh: shown only where the API exists; P7-7 decides whether it stays.
- **Names across tasks:** `orderBoards`/`GetBoards` (1) → `GetOrders` (3) → selection (4) → new-order diff (5);
  `GetMailCount`/`GetListedCount` (6) → restock (7) and gather (15); `FeatureLines` (8) → providers in 12 and 14;
  `opts.optionalItemIDs`/`optionalAllocation`/`BestOptionals` (11) → 12, 13; `Queue:Add(entry, opts)` (14) → 15;
  `CraftOption`/`GetChoice`/`SetChoice` (14) → 15; `click_only` (5) → 16, 17, 19; `ChatInbox:Latest/Reply` (18) → 19.
- **Proportion:** code appears only for the migration and recursion rules' tests, the Bindings file (exact copy), and
  test assertions.

## Pre-flight conflict table

| # | Tasks | Shared file / interface | Risk | Resolution |
|---|---|---|---|---|
| 1 | 1 → 3 → 5 | `Modules/Orders.lua` board section | three tasks edit `OnBoardShown` | Sequential. Task 1 owns the board shape, Task 3 adds only `GetOrders`, Task 5 adds the diff before the replacement loop and `RequestBoard` after `ClaimBest`. |
| 2 | 1 | specs that seed `ordersSnapshot` (board, orders tab, ledger tab, db) | broken by the migration | Task 1 rewrites exactly those lines (listed in its Files). |
| 3 | 2 → 3, 4 | `Orders.RISKS` and `OrdersPanel.FilterChecks()` | a new checkbox changes counts in `orders_tab_spec` / `orders_panel_spec` | Task 2 updates every count it changes; Tasks 3 and 4 add their controls after the checks. |
| 4 | 3 → 4 | `UI/Tabs/Orders.lua` `COLUMNS` / `HIDE_ORDER` | both add columns | Task 3 adds `character` (hidden first); Task 4 puts `select` first and never hides it. |
| 5 | 4 → 13, 15 | `Queue:GetMissingForEntries`, `ExportShoppingList(onRetry, opts)` | later callers | Interfaces fixed in Task 4; 13 and 15 only call them. |
| 6 | 6 → 7, 15 | Scanner mail; kind `"mail"` | a consumer bumping stamps on `"mail"` | Task 6 makes Recipes ignore it and tests it; the Queue's recompute debounce may run on it (harmless). |
| 7 | 6 ↔ Ledger | mail events and hooks | double-counted sales | SaleLog never records sales; it reads the Ledger's. It ignores cancelled-auction mail. |
| 8 | 7 → 13 → 15 | `UI/Tabs/Queue.lua` | restock panel, then sections | The restock panel stays in the Queue section; Task 13 adds the section row with `queue`, `lists`; Task 15 appends `gather`. |
| 9 | 8 → 10 | `UI/Tabs/Ledger.lua` sections | both add sections | Task 8 adds the row and `auctions`; Task 10 appends `crafts`. |
| 10 | 9 ↔ Ledger | two `CraftRecipe` post-hooks, two `TRADE_SKILL_ITEM_CRAFTED_RESULT` handlers | the structural spec; shared state | Task 9 widens the spec to one line per file; the two modules keep separate pending state. |
| 11 | 11 → 14 | `Recipes` `full_opts` / `evaluate` | `optionalItemIDs` (cached) and `reagentPrices` (uncached) | Task 11 adds the sixth key; Task 14 reads `reagentPrices` before `full_opts`, like `extraStats`; a call with both is uncached and applies both. |
| 12 | 12 → 14 | `UI/FeatureLines.lua` panel providers | display order | Registration order: `optionals` (12), then `intermediates` (14). |
| 13 | 12 → 14 → 16 | `Queue:Add`, `per_craft`, `shortfalls` | three edits | Sequential; Task 12 adds the optional need, Task 14 the `opts`/`parentID`, Task 16 exposes `GetRequired` over the same local. |
| 14 | 5 → 16, 17, 19 | `tests/helpers/click_only.lua` | helper shape | Fixed in Task 5 (`only_inside`, `referenced_only_from_onclick`); later tasks only call it. |
| 15 | 5, 6, 16, 17 | `tests/helpers/wow_stubs.lua` defaults and `wow_stubs_spec.lua` | inert fakes breaking existing specs | Every fake is inert by default (returns 0/nil, no-op, records only); each task extends `wow_stubs_spec.lua` for its fakes. |
| 16 | 18 → 19 | `ChatInbox:Latest` / `Reply` | the binding | Fixed in Task 18's Interfaces. |
| 17 | 19 ↔ release | `Bindings.xml` outside the TOC | the release spec's TOC-only check | Task 19 adds it to the shipped-files list, not the TOC. |
| 18 | all | `Locales/enUS.lua`, `FabricationStation.toc`, `.luacheckrc`, the contract | concurrent additions | Sequential; each task adds only its keys, files and globals; the unused-key check catches leftovers. |
| 19 | all | `docs/in-game-checklist.md` `## Phase 7` | numbering | Task 1 creates the section; the P7 numbers are pre-assigned per task (1: 1; 2: 2–3; 3: 4; 4: 5; 5: 6–8; 6: 9–13; 7: 14; 8: 15; 9: 16–17; 10: 18; 11: 19; 12: 20; 13: 21; 14: 22; 15: 23; 16: 24–25; 17: 26; 18: 27; 19: 28; 20: 29). Each task appends at the end. |
| 20 | 5 ↔ Planner | concentration chat lines | the same state announced twice | ReadyAlerts skips concentration at login while the Planner's `capWarnChat` announces it; during play only ReadyAlerts alerts. |
| 21 | 13 ↔ Planner tab | Concentration section footer | the Queue plan button next to the existing per-row Queue buttons | The footer button reuses the row path's checks (`Queue` off, read-only) and the same notice line. |
